# frozen_string_literal: true

require "mini_mime"
require "file_store/s3_store"

module BackupRestore

  class Backuper
    attr_reader :success

    def initialize(user_id, opts = {})
      @user_id = user_id
      @client_id = opts[:client_id]
      @publish_to_message_bus = opts[:publish_to_message_bus] || false
      @with_uploads = opts[:with_uploads].nil? ? true : opts[:with_uploads]
      @filename_override = opts[:filename]

      ensure_no_operation_is_running
      ensure_we_have_a_user

      initialize_state
    end

    def run
      log "[STARTED]"
      log "'#{@user.username}' has started the backup!"

      mark_backup_as_running

      listen_for_shutdown_signal

      ensure_directory_exists(@tmp_directory)
      ensure_directory_exists(@archive_directory)

      update_metadata

      begin
        pause_sidekiq
        wait_for_sidekiq
        dump_public_schema
      ensure
        unpause_sidekiq
      end

      log "Finalizing backup..."

      @with_uploads ? create_archive : move_dump_backup
      upload_archive

      after_create_hook
    rescue SystemExit
      log "Backup process was cancelled!"
    rescue Exception => ex
      log "EXCEPTION: " + ex.message
      log ex.backtrace.join("\n")
      @success = false
    else
      @success = true
      @backup_filename
    ensure
      delete_old
      clean_up
      notify_user
      log "Finished!"

      @success ? log("[SUCCESS]") : log("[FAILED]")
    end

    protected

    def ensure_no_operation_is_running
      raise BackupRestore::OperationRunningError if BackupRestore.is_operation_running?
    end

    def ensure_we_have_a_user
      @user = User.find_by(id: @user_id)
      raise Discourse::InvalidParameters.new(:user_id) unless @user
    end

    def get_parameterized_title
      SiteSetting.title.parameterize.presence || "discourse"
    end

    def initialize_state
      @success = false
      @store = BackupRestore::BackupStore.create
      @current_db = RailsMultisite::ConnectionManagement.current_db
      @timestamp = Time.now.strftime("%Y-%m-%d-%H%M%S")
      @tmp_directory = File.join(Rails.root, "tmp", "backups", @current_db, @timestamp)
      @dump_filename = File.join(@tmp_directory, BackupRestore::DUMP_FILE)
      @archive_directory = BackupRestore::LocalBackupStore.base_directory(db: @current_db)
      filename = @filename_override || "#{get_parameterized_title}-#{@timestamp}"
      @archive_basename = File.join(@archive_directory, "#{filename}-#{BackupRestore::VERSION_PREFIX}#{BackupRestore.current_version}")

      @backup_filename =
        if @with_uploads
          "#{File.basename(@archive_basename)}.tar.gz"
        else
          "#{File.basename(@archive_basename)}.sql.gz"
        end

      @logs = []
    end

    def listen_for_shutdown_signal
      Thread.new do
        while BackupRestore.is_operation_running?
          exit if BackupRestore.should_shutdown?
          sleep 0.1
        end
      end
    end

    def mark_backup_as_running
      log "Marking backup as running..."
      BackupRestore.mark_as_running!
    end

    def update_metadata
      log "Updating metadata..."
      BackupMetadata.delete_all
      BackupMetadata.create!(name: "base_url", value: Discourse.base_url)
      BackupMetadata.create!(name: "cdn_url", value: Discourse.asset_host)
      BackupMetadata.create!(name: "s3_base_url", value: SiteSetting.Upload.enable_s3_uploads ? SiteSetting.Upload.s3_base_url : nil)
      BackupMetadata.create!(name: "s3_cdn_url", value: SiteSetting.Upload.enable_s3_uploads ? SiteSetting.Upload.s3_cdn_url : nil)
      BackupMetadata.create!(name: "db_name", value: RailsMultisite::ConnectionManagement.current_db)
      BackupMetadata.create!(name: "multisite", value: Rails.configuration.multisite)
    end

    def pause_sidekiq
      log "Pausing sidekiq..."
      Sidekiq.pause!
    end

    def wait_for_sidekiq
      log "Waiting for sidekiq to finish running jobs..."
      iterations = 1
      while sidekiq_has_running_jobs?
        log "Waiting for sidekiq to finish running jobs... ##{iterations}"
        sleep 5
        iterations += 1
        raise "Sidekiq did not finish running all the jobs in the allowed time!" if iterations > 6
      end
    end

    def sidekiq_has_running_jobs?
      Sidekiq::Workers.new.each do |_, _, worker|
        payload = worker.try(:payload)
        return true if payload.try(:all_sites)
        return true if payload.try(:current_site_id) == @current_db
      end

      false
    end

    def dump_public_schema
      log "Dumping the public schema of the database..."

      logs = Queue.new
      pg_dump_running = true

      Thread.new do
        RailsMultisite::ConnectionManagement::establish_connection(db: @current_db)
        while pg_dump_running
          message = logs.pop.strip
          log(message) unless message.blank?
        end
      end

      IO.popen("#{pg_dump_command} 2>&1") do |pipe|
        begin
          while line = pipe.readline
            logs << line
          end
        rescue EOFError
          # finished reading...
        ensure
          pg_dump_running = false
          logs << ""
        end
      end

      raise "pg_dump failed" unless $?.success?
    end

    def pg_dump_command
      db_conf = BackupRestore.database_configuration

      password_argument = "PGPASSWORD='#{db_conf.password}'" if db_conf.password.present?
      host_argument     = "--host=#{db_conf.host}"         if db_conf.host.present?
      port_argument     = "--port=#{db_conf.port}"         if db_conf.port.present?
      username_argument = "--username=#{db_conf.username}" if db_conf.username.present?

      [ password_argument,            # pass the password to pg_dump (if any)
        "pg_dump",                    # the pg_dump command
        "--schema=public",            # only public schema
        "-T public.pg_*",             # exclude tables and views whose name starts with "pg_"
        "--file='#{@dump_filename}'", # output to the dump.sql file
        "--no-owner",                 # do not output commands to set ownership of objects
        "--no-privileges",            # prevent dumping of access privileges
        "--verbose",                  # specifies verbose mode
        "--compress=4",               # Compression level of 4
        host_argument,                # the hostname to connect to (if any)
        port_argument,                # the port to connect to (if any)
        username_argument,            # the username to connect as (if any)
        db_conf.database              # the name of the database to dump
      ].join(" ")
    end

    def move_dump_backup
      log "Finalizing database dump file: #{@backup_filename}"

      archive_filename = File.join(@archive_directory, @backup_filename)

      Discourse::Utils.execute_command(
        'mv', @dump_filename, archive_filename,
        failure_message: "Failed to move database dump file."
      )

      remove_tmp_directory
    end

    def create_archive
      log "Creating archive: #{@backup_filename}"

      tar_filename = "#{@archive_basename}.tar"

      log "Making sure archive does not already exist..."
      Discourse::Utils.execute_command('rm', '-f', tar_filename)
      Discourse::Utils.execute_command('rm', '-f', "#{tar_filename}.gz")

      log "Creating empty archive..."
      Discourse::Utils.execute_command('tar', '--create', '--file', tar_filename, '--files-from', '/dev/null')

      log "Archiving data dump..."
      Discourse::Utils.execute_command(
        'tar', '--append', '--dereference', '--file', tar_filename, File.basename(@dump_filename),
        failure_message: "Failed to archive data dump.",
        chdir: File.dirname(@dump_filename)
      )

      add_local_uploads_to_archive(tar_filename)
      add_remote_uploads_to_archive(tar_filename) if SiteSetting.Upload.enable_s3_uploads

      remove_tmp_directory

      log "Gzipping archive, this may take a while..."
      Discourse::Utils.execute_command(
        'gzip', "-#{SiteSetting.backup_gzip_compression_level_for_uploads}", tar_filename,
        failure_message: "Failed to gzip archive."
      )
    end

    def add_local_uploads_to_archive(tar_filename)
      log "Archiving uploads..."
      upload_directory = Discourse.store.upload_path

      if File.directory?(File.join(Rails.root, "public", upload_directory))
        exclude_optimized = SiteSetting.include_thumbnails_in_backups ? '' : "--exclude=#{upload_directory}/optimized"

        Discourse::Utils.execute_command(
          'tar', '--append', '--dereference', exclude_optimized, '--file', tar_filename, upload_directory,
          failure_message: "Failed to archive uploads.", success_status_codes: [0, 1],
          chdir: File.join(Rails.root, "public")
        )
      else
        log "No local uploads found. Skipping archiving of local uploads..."
      end
    end

    def add_remote_uploads_to_archive(tar_filename)
      if !SiteSetting.include_s3_uploads_in_backups
        log "Skipping uploads stored on S3."
        return
      end

      log "Downloading uploads from S3. This may take a while..."

      store = FileStore::S3Store.new
      upload_directory = Discourse.store.upload_path
      count = 0

      Upload.find_each do |upload|
        next if upload.local?
        filename = File.join(@tmp_directory, upload_directory, store.get_path_for_upload(upload))

        begin
          FileUtils.mkdir_p(File.dirname(filename))
          store.download_file(upload, filename)
        rescue StandardError => ex
          log "Failed to download file with upload ID #{upload.id} from S3", ex
        end

        count += 1
        log "#{count} files have already been downloaded. Still downloading..." if count % 500 == 0
      end

      log "Appending uploads to archive..."
      Discourse::Utils.execute_command(
        'tar', '--append', '--file', tar_filename, upload_directory,
        failure_message: "Failed to append uploads to archive.", success_status_codes: [0, 1],
        chdir: @tmp_directory
      )

      log "No uploads found on S3. Skipping archiving of uploads stored on S3..." if count == 0
    end

    def upload_archive
      return unless @store.remote?

      log "Uploading archive..."
      content_type = MiniMime.lookup_by_filename(@backup_filename).content_type
      archive_path = File.join(@archive_directory, @backup_filename)
      @store.upload_file(@backup_filename, archive_path, content_type)
    end

    def after_create_hook
      log "Executing the after_create_hook for the backup..."
      DiscourseEvent.trigger(:backup_created)
    end

    def delete_old
      return if Rails.env.development?

      log "Deleting old backups..."
      @store.delete_old
    rescue => ex
      log "Something went wrong while deleting old backups.", ex
    end

    def notify_user
      return if @success && @user.id == Discourse::SYSTEM_USER_ID

      log "Notifying '#{@user.username}' of the end of the backup..."
      status = @success ? :backup_succeeded : :backup_failed

      post = SystemMessage.create_from_system_user(
        @user, status, logs: Discourse::Utils.pretty_logs(@logs)
      )

      if @user.id == Discourse::SYSTEM_USER_ID
        post.topic.invite_group(@user, Group[:admins])
      end
    rescue => ex
      log "Something went wrong while notifying user.", ex
    end

    def clean_up
      log "Cleaning stuff up..."
      delete_uploaded_archive
      remove_tar_leftovers
      mark_backup_as_not_running
      refresh_disk_space
    end

    def delete_uploaded_archive
      return unless @store.remote?

      archive_path = File.join(@archive_directory, @backup_filename)

      if File.exist?(archive_path)
        log "Removing archive from local storage..."
        File.delete(archive_path)
      end
    rescue => ex
      log "Something went wrong while deleting uploaded archive from local storage.", ex
    end

    def refresh_disk_space
      log "Refreshing disk stats..."
      @store.reset_cache
    rescue => ex
      log "Something went wrong while refreshing disk stats.", ex
    end

    def remove_tar_leftovers
      log "Removing '.tar' leftovers..."
      Dir["#{@archive_directory}/*.tar"].each { |filename| File.delete(filename) }
    rescue => ex
      log "Something went wrong while removing '.tar' leftovers.", ex
    end

    def remove_tmp_directory
      log "Removing tmp '#{@tmp_directory}' directory..."
      FileUtils.rm_rf(@tmp_directory) if Dir[@tmp_directory].present?
    rescue => ex
      log "Something went wrong while removing the following tmp directory: #{@tmp_directory}", ex
    end

    def unpause_sidekiq
      return unless Sidekiq.paused?
      log "Unpausing sidekiq..."
      Sidekiq.unpause!
    rescue => ex
      log "Something went wrong while unpausing Sidekiq.", ex
    end

    def mark_backup_as_not_running
      log "Marking backup as finished..."
      BackupRestore.mark_as_not_running!
    rescue => ex
      log "Something went wrong while marking backup as finished.", ex
    end

    def ensure_directory_exists(directory)
      log "Making sure '#{directory}' exists..."
      FileUtils.mkdir_p(directory)
    end

    def log(message, ex = nil)
      timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
      puts(message)
      publish_log(message, timestamp)
      save_log(message, timestamp)
      Rails.logger.error("#{ex}\n" + ex.backtrace.join("\n")) if ex
    end

    def publish_log(message, timestamp)
      return unless @publish_to_message_bus
      data = { timestamp: timestamp, operation: "backup", message: message }
      MessageBus.publish(BackupRestore::LOGS_CHANNEL, data, user_ids: [@user_id], client_ids: [@client_id])
    end

    def save_log(message, timestamp)
      @logs << "[#{timestamp}] #{message}"
    end

  end

end
