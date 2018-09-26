#
# Copyright 2014 Chef Software, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "socket"

module Omnibus
  class Packager::Solaris < Packager::Base
    # @return [Hash]
    SCRIPT_MAP = {
      # Default Omnibus naming
      postinst:  "postinstall",
      postrm: "postremove",
      # Default Solaris naming
      postinstall:  "postinstall",
      postremove: "postremove",
    }.freeze

    id :solaris

    build do
      write_scripts
      copy_files
      write_prototype_file
      write_pkginfo_file
      create_solaris_file
    end

    # @see Base#package_name
    def package_name
      "#{project.package_name}-#{pkgmk_version}.#{safe_architecture}.solaris"
    end

    def pkgmk_version
      "#{project.build_version}-#{project.build_iteration}"
    end

    def install_dirname
      File.dirname(project.install_dir)
    end

    def install_basename
      File.basename(project.install_dir)
    end

    def root_dir
      "#{staging_dir}/root"
    end

    def filesystem_directories
      @filesystem_directories ||= IO.readlines(resource_path("filesystem_list")).map { |f| f.chomp }
    end

    def filesystem_dir?(fsdir)
      filesystem_directories.include?(fsdir)
    end

    #
    # Copy stuff
    #
    def copy_files
      # Copy the full-stack installer into our scratch directory, accounting for
      # any excluded files.
      #
      # /opt/hamlet => /tmp/daj29013/opt/hamlet
      destination = File.join(root_dir, project.install_dir)
      FileSyncer.sync(project.install_dir, destination, exclude: exclusions)

      # Copy over any user-specified extra package files.
      #
      # Files retain their relative paths inside the scratch directory, so
      # we need to grab the dirname of the file, create that directory, and
      # then copy the file into that directory.
      #
      # extra_package_file '/path/to/foo.txt' #=> /tmp/scratch/path/to/foo.txt
      project.extra_package_files.each do |file|
        parent = File.dirname(file)
        if File.directory?(file)
          destination = File.join(root_dir, file)
          create_directory(destination)
          FileSyncer.sync(file, destination)
        else
          destination = File.join(root_dir, parent)
          create_directory(destination)
          copy_file(file, destination)
        end
      end
    end

    #
    # Copy all scripts in {Project#package_scripts_path} to the control
    # directory of this repo.
    #
    # @return [void]
    #
    def write_scripts
      SCRIPT_MAP.each do |source, destination|
        source_path = File.join(project.package_scripts_path, source.to_s)

        next unless File.file?(source_path)

        destination_path = staging_dir_path(destination)
        log.debug(log_key) { "Adding script `#{source}' to `#{destination_path}'" }
        copy_file(source_path, destination_path)
      end
    end

    #
    # Generate a Prototype file for solaris build
    #
    def write_prototype_file
      shellout! "cd #{root_dir} && find . -print > #{staging_dir_path('files')}"

      File.open staging_dir_path("files.clean"), "w+" do |fout|
        File.open staging_dir_path("files") do |fin|
          fin.each_line do |line|
            if line.chomp =~ /\s/
              log.warn(log_key) { "Skipping packaging '#{line.chomp}' file due to whitespace in filename" }
            elsif filesystem_dir?(line.chomp[1..-1])
              log.info(log_key) { "Skipping packaging '#{line.chomp}' file as it is a filesystem directory" }
            else
              fout.write(line)
            end
          end
        end
      end

      # generate list of control files
      File.open staging_dir_path("Prototype"), "w+" do |f|
        f.write <<-EOF.gsub(/^ {10}/, "")
          i pkginfo
          i postinstall
          i postremove
        EOF
      end

      # generate the prototype's file list
      shellout! "cd #{root_dir} && pkgproto < #{staging_dir_path('files.clean')} > #{staging_dir_path('Prototype.files')}"

      # fix up the user and group in the file list to root
      shellout! "awk '{ $5 = \"root\"; $6 = \"root\"; print }' < #{staging_dir_path('Prototype.files')} >> #{staging_dir_path('Prototype')}"
    end

    #
    # Generate a pkginfo file for solaris build
    #
    def write_pkginfo_file
      hostname = Socket.gethostname

      # http://docs.oracle.com/cd/E19683-01/816-0219/6m6njqbat/index.html
      pkginfo_content = <<-EOF.gsub(/^ {8}/, "")
        CLASSES=none
        TZ=PST
        PATH=/sbin:/usr/sbin:/usr/bin:/usr/sadm/install/bin
        BASEDIR=/
        PKG=#{project.package_name}
        NAME=#{project.package_name}
        ARCH=#{safe_architecture}
        VERSION=#{pkgmk_version}
        CATEGORY=application
        DESC=#{project.description}
        VENDOR=#{project.maintainer}
        EMAIL=#{project.maintainer}
        PSTAMP=#{hostname}#{Time.now.utc.iso8601}
      EOF
      File.open staging_dir_path("pkginfo"), "w+" do |f|
        f.write pkginfo_content
      end
    end

    #
    # Generate the Solaris file using +pkg*+.
    #
    # @return [void]
    #
    def create_solaris_file
      shellout! "pkgmk -o -r / -d #{root_dir} -f #{staging_dir_path('Prototype')}"
      shellout! "pkgchk -vd #{root_dir} #{project.package_name}"
      shellout! "pkgtrans #{root_dir} #{package_path} #{project.package_name}"
    end

    #
    # The architecture for this Solaris package.
    #
    # @return [String]
    #
    def safe_architecture
      # The #i386? and #intel? helpers come from chef-sugar
      if intel?
        "i386"
      elsif sparc?
        "sparc"
      else
        Ohai["kernel"]["machine"]
      end
    end
  end
end
