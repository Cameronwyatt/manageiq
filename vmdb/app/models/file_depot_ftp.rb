require 'net/ftp'

class FileDepotFtp < FileDepot
  def self.uri_prefix
    "ftp"
  end

  def self.validate(settings)
    depot = new(:uri => settings[:uri])
    depot.with_connection(:username => settings[:username], :password => settings[:password]) { |c| c.last_response }
  end

  def upload_file(file)
    log_header = "MIQ(#{self.class.name}##{__method__})"
    super
    with_connection do |ftp|
      begin
        return if destination_file_exists?(ftp, destination_file)

        create_directory_structure(ftp)
        $log.info("#{log_header} Uploading file: #{destination_file} to File Depot: #{name}...")
        ftp.putbinaryfile(file.local_file, destination_file)
      rescue => err
        msg = "Error '#{err.message.chomp}', writing to FTP: [#{uri}], Username: [#{authentication_userid}]"
        $log.error("#{log_header} #{msg}")
        raise msg
      else
        file.update_attributes(
          :state   => "available",
          :log_uri => destination_file
        )
        $log.info("#{log_header} Uploading file: #{destination_file}... Complete")
        file.post_upload_tasks
      end
    end
  end

  def remove_file(file)
    log_header = "MIQ(#{self.class.name}##{__method__})"
    @file = file
    $log.info("#{log_header} Removing log file [#{destination_file}]...")
    with_connection do |ftp|
      ftp.delete(destination_file)
    end
    $log.info("#{log_header} Removing log file [#{destination_file}]...complete")
  end

  def verify_credentials(_auth_type = nil)
    with_connection { |c| c.last_response }
  rescue
    false
  end

  def with_connection(cred_hash = nil)
    raise "no block given" unless block_given?
    $log.info("MIQ(#{self.class.name}##{__method__}) Connecting through #{self.class.name}: [#{name}]")
    begin
      connection = connect(cred_hash)
      yield connection
    ensure
      connection.try(:close)
    end
  end

  def connect(cred_hash = nil)
    log_header = "MIQ(#{self.class.name}##{__method__})"
    host       = URI.split(URI.encode(uri))[2]

    begin
      $log.info("#{log_header} Connecting to #{self.class.name}: #{name} host: #{host}...")
      ftp         = Net::FTP.new(host)
      ftp.passive = true  # Use passive mode to avoid firewall issues see http://slacksite.com/other/ftp.html#passive
      # ftp.debug_mode = true if settings[:debug]  # TODO: add debug option
      creds = cred_hash ? [cred_hash[:username], cred_hash[:password]] : login_credentials
      ftp.login(*creds)
      $log.info("#{log_header} Connected to #{self.class.name}: #{name} host: #{host}")
    rescue SocketError => err
      $log.error("#{log_header} Failed to connect.  #{err.message}")
      raise
    rescue Net::FTPPermError => err
      $log.error("#{log_header} Failed to login.  #{err.message}")
      raise
    else
      ftp
    end
  end

  private

  def create_directory_structure(ftp)
    $log.info("MIQ(#{self.class.name}##{__method__}) Creating directory structure on server...")
    ftp.mkdir(destination_path)
  rescue Net::FTPPermError => err
    return if err.message.to_s.strip.start_with?("521")  # path already exists.
    raise
  end

  def destination_file_exists?(ftp, file)
    $log.info("MIQ(#{self.class.name}##{__method__}) Checking for log file #{file} on server...")
    result = ftp.ls(file).present?
    $log.info("MIQ(#{self.class.name}##{__method__}) Found file: #{file} on server... skipping") if result
    result
  end

  def destination_file
    File.join(destination_path, file.destination_file_name)
  end

  def destination_path
    File.join(base_path, file.destination_directory)
  end

  def base_path
    # URI.split(URI.encode("ftp://ftp.example.com/incoming"))[5]  => "/incoming"
    URI.split(URI.encode(uri))[5]
  end

  def login_credentials
    [authentication_userid, authentication_password]
  end
end
