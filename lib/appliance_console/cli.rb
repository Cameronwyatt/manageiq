require 'trollop'
require 'pathname'
require 'appliance_console/env'
require 'appliance_console/utilities'
require 'appliance_console/logging'
require 'appliance_console/database_configuration'
require 'appliance_console/internal_database_configuration'
require 'appliance_console/external_database_configuration'
require 'appliance_console/external_httpd_authentication'
require 'appliance_console/service_group'
require 'appliance_console/temp_storage_configuration'
require 'appliance_console/key_configuration'
require 'appliance_console/principal'
require 'appliance_console/certificate'
require 'appliance_console/certificate_authority'

# support for appliance_console methods
unless defined?(say)
  def say(arg)
    puts(arg)
  end
end

module ApplianceConsole
  class Cli
    attr_accessor :options

    # machine host
    def host
      options[:host] || Env["host"]
    end

    # database hostname
    def hostname
      options[:internal] ? "localhost" : options[:hostname]
    end

    def local?(name = hostname)
      name.presence.in?(["localhost", "127.0.0.1", nil])
    end

    def key?
      options[:key] || options[:fetch_key] || (local_database? && !key_configuration.key_exist?)
    end

    def database?
      hostname
    end

    def local_database?
      hostname && local?(hostname)
    end

    def certs?
      options[:postgres_client_cert] || options[:postgres_server_cert] || options[:api_cert]
    end

    def initialize(options = {})
      self.options = options
    end

    def disk_from_string(path)
      return if path.blank?
      path == "auto" ? disk : disk_by_path(path)
    end

    def disk
      LinuxAdmin::Disk.local.detect { |d| d.partitions.empty? }
    end

    def disk_by_path(path)
      LinuxAdmin::Disk.local.detect { |d| d.path == path }
    end

    def parse(args)
      args.shift if args.first == "--" # Handle when called through script/runner
      self.options = Trollop.options(args) do
        banner "Usage: appliance_console_cli [options]"

        opt :host,     "/etc/hosts name",    :type => :string,  :short => 'H'
        opt :region,   "Region Number",      :type => :integer, :short => "r"
        opt :internal, "Internal Database",                     :short => 'i'
        opt :hostname, "Database Hostname",  :type => :string,  :short => 'h'
        opt :username, "Database Username",  :type => :string,  :short => 'U', :default => "root"
        opt :password, "Database Password",  :type => :string,  :short => "p"
        opt :dbname,   "Database Name",      :type => :string,  :short => "d", :default => "vmdb_production"
        opt :key,      "Create encryption key",  :type => :boolean, :short => "k"
        opt :fetch_key, "SSH host with encryption key", :type => :string, :short => "K"
        opt :force_key, "Forcefully create encryption key", :type => :boolean, :short => "f"
        opt :sshlogin,  "SSH login",         :type => :string,                 :default => "root"
        opt :sshpassword, "SSH password",    :type => :string
        opt :verbose,  "Verbose",            :type => :boolean, :short => "v"
        opt :dbdisk,   "Database Disk Path", :type => :string
        opt :tmpdisk,   "Temp storage Disk Path", :type => :string
        opt :uninstall_ipa, "Uninstall IPA Client", :type => :boolean,         :default => false
        opt :ipaserver,  "IPA Server FQDN",  :type => :string
        opt :ipaprincipal,  "IPA Server principal", :type => :string,          :default => "admin"
        opt :ipapassword,   "IPA Server password",  :type => :string
        opt :iparealm,      "IPA Server realm (optional)", :type => :string
        opt :ca,                   "CA name used for certmonger",       :type => :string,  :default => "ipa"
        opt :postgres_client_cert, "install certs for postgres client", :type => :boolean
        opt :postgres_server_cert, "install certs for postgres server", :type => :boolean
        opt :api_cert,             "install certs for regional api",    :type => :boolean
      end
      Trollop.die :region, "needed when setting up a local database" if options[:region].nil? && local_database?
      self
    end

    def run
      Env[:host] = options[:host] if options[:host]
      create_key if key?
      set_db if hostname
      config_tmp_disk if options[:tmpdisk]
      uninstall_ipa if options[:uninstall_ipa]
      install_ipa if options[:ipaserver]
      install_certs if certs?
    rescue AwesomeSpawn::CommandResultError => e
      say e.result.output
      say e.result.error
      say ""
      raise
    end

    def set_db
      raise "No v2_key present" unless key_configuration.key_exist?
      if local?
        set_internal_db
      else
        set_external_db
      end
    end

    def set_internal_db
      say "configuring internal database"
      config = ApplianceConsole::InternalDatabaseConfiguration.new({
        :database    => options[:dbname],
        :region      => options[:region],
        :username    => options[:username],
        :password    => options[:password],
        :interactive => false,
        :disk        => disk_from_string(options[:dbdisk])
      }.delete_if { |_n, v| v.nil? })

      # create partition, pv, vg, lv, ext4, update fstab, mount disk
      # initdb, relabel log directory for selinux, update configs,
      # start pg, create user, create db update the rails configuration,
      # verify, set up the database with region. activate does it all!
      config.activate

      # enable/start related services
      config.post_activation
    end

    def set_external_db
      say "configuring external database"
      config = ApplianceConsole::ExternalDatabaseConfiguration.new({
        :host        => options[:hostname],
        :database    => options[:dbname],
        :region      => options[:region],
        :username    => options[:username],
        :password    => options[:password],
        :interactive => false,
      }.delete_if { |_n, v| v.nil? })

      # call create_or_join_region (depends on region value)
      config.activate

      # enable/start related services
      config.post_activation
    end

    def key_configuration
      @key_configuration ||= KeyConfiguration.new(
        :action   => options[:fetch_key] ? :fetch : :create,
        :force    => options[:fetch_key] ? true : options[:force_key],
        :host     => options[:fetch_key],
        :login    => options[:sshlogin],
        :password => options[:sshpassword],
      )
    end

    def create_key
      say "#{key_configuration.action} encryption key"
      unless key_configuration.activate
        raise "Could not create encryption key (v2_key)"
      end
    end

    def install_certs
      say "creating ssl certificates"
      config = CertificateAuthority.new(
        :hostname => host,
        :realm    => options[:iparealm],
        :ca_name  => options[:ca],
        :pgclient => options[:postgres_client_cert],
        :pgserver => options[:postgres_server_cert],
        :api      => options[:api_cert],
        :verbose  => options[:verbose],
      )

      config.activate
      say "\ncertificate result: #{config.status_string}"
      unless config.complete?
        say "After the certificates are retrieved, rerun to update service configuration files"
      end
    end

    def install_ipa
      raise "please uninstall ipa before reinstalling" if ExternalHttpdAuthentication.ipa_client_configured?
      config = ExternalHttpdAuthentication.new(
        host,
        :ipaserver => options[:ipaserver],
        :realm     => options[:iparealm],
        :principal => options[:ipaprincipal],
        :password  => options[:ipapassword],
      )

      config.post_activation if config.activate
    end

    def uninstall_ipa
      say "Uninstalling IPA-client"
      config = ExternalHttpdAuthentication.new
      config.ipa_client_unconfigure if config.ipa_client_configured?
    end

    def config_tmp_disk
      say "creating temp disk"
      if (tmp_disk = disk_from_string(options[:tmpdisk]))
        config = ApplianceConsole::TempStorageConfiguration.new(:disk => tmp_disk)
        config.activate
      else
        say "could not find disk #{options[:tmpdisk]}"
        say "if you pass auto, it will choose: #{disk.try(:path) || "no disks with a free partition"}"
      end
    end

    def self.parse(args)
      new.parse(args).run
    end
  end
end
