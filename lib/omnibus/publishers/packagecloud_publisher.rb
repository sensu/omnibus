require "packagecloud"

module Omnibus
  class PackagecloudPublisher < Publisher
    def publish(&block)
      log.info(log_key) { "Starting packagecloud publisher" }

      # Create a client using your username and API token
      credentials = Packagecloud::Credentials.new(Config.packagecloud_user, Config.packagecloud_token)
      client = Packagecloud::Client.new(credentials)

      packages.each do |package|
        # Make sure the package is good to go!
        log.debug(log_key) { "Validating '#{package.name}'" }
        package.validate!

        # Upload the package
        pkg = Packagecloud::Package.new(:file => package.path)

        distros.each do |distro|
          log.info(log_key) { "Uploading '#{package.name}' to '#{distro}' distribution in '#{@options[:repo]}' repository" }
          client.put_package(@options[:repo], pkg, distro)
        end

        # If a block was given, "yield" the package to the caller
        yield(package) if block
      end
    end

    private

    def distros
      Config.packagecloud_distros.split(",")
    end
  end
end
