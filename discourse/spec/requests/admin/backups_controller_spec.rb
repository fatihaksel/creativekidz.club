# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::BackupsController do
  fab!(:admin) { Fabricate(:admin) }
  let(:backup_filename) { "2014-02-10-065935.tar.gz" }
  let(:backup_filename2) { "2014-02-11-065935.tar.gz" }

  def create_backup_files(*filenames)
    @paths = filenames.map do |filename|
      path = backup_path(filename)
      File.open(path, "w") { |f| f.write("test backup") }
      path
    end
  end

  def backup_path(filename)
    File.join(BackupRestore::LocalBackupStore.base_directory, filename)
  end

  def map_preloaded
    controller.instance_variable_get("@preloaded").map do |key, value|
      [key, JSON.parse(value)]
    end.to_h
  end

  it "is a subclass of AdminController" do
    expect(Admin::BackupsController < Admin::AdminController).to eq(true)
  end

  before do
    sign_in(admin)
    SiteSetting.backup_location = BackupLocationSiteSetting::LOCAL
  end

  after do
    Discourse.redis.flushall

    @paths&.each { |path| File.delete(path) if File.exists?(path) }
    @paths = nil
  end

  describe "#index" do
    it "raises an error when backups are disabled" do
      SiteSetting.enable_backups = false
      get "/admin/backups.json"
      expect(response.status).to eq(403)
    end

    context "html format" do
      it "preloads important data" do
        get "/admin/backups.html"
        expect(response.status).to eq(200)

        preloaded = map_preloaded
        expect(preloaded["operations_status"].symbolize_keys).to eq(BackupRestore.operations_status)
        expect(preloaded["logs"].size).to eq(BackupRestore.logs.size)
      end
    end

    context "json format" do
      it "returns a list of all the backups" do
        begin
          create_backup_files(backup_filename, backup_filename2)

          get "/admin/backups.json"
          expect(response.status).to eq(200)

          filenames = JSON.parse(response.body).map { |backup| backup["filename"] }
          expect(filenames).to include(backup_filename)
          expect(filenames).to include(backup_filename2)
        end
      end
    end
  end

  describe '#status' do
    it "returns the current backups status" do
      get "/admin/backups/status.json"
      expect(response.body).to eq(BackupRestore.operations_status.to_json)
      expect(response.status).to eq(200)
    end
  end

  describe '#create' do
    it "starts a backup" do
      BackupRestore.expects(:backup!).with(admin.id, publish_to_message_bus: true, with_uploads: false, client_id: "foo")

      post "/admin/backups.json", params: {
        with_uploads: false, client_id: "foo"
      }

      expect(response.status).to eq(200)
    end
  end

  describe '#show' do
    it "uses send_file to transmit the backup" do
      begin
        token = EmailBackupToken.set(admin.id)
        create_backup_files(backup_filename)

        expect do
          get "/admin/backups/#{backup_filename}.json", params: { token: token }
        end.to change { UserHistory.where(action: UserHistory.actions[:backup_download]).count }.by(1)

        expect(response.headers['Content-Length']).to eq("11")
        expect(response.headers['Content-Disposition']).to match(/attachment; filename/)
      end
    end

    it "returns 422 when token is bad" do
      begin
        get "/admin/backups/#{backup_filename}.json", params: { token: "bad_value" }

        expect(response.status).to eq(422)
        expect(response.headers['Content-Disposition']).not_to match(/attachment; filename/)
      end
    end

    it "returns 404 when the backup does not exist" do
      token = EmailBackupToken.set(admin.id)
      get "/admin/backups/#{backup_filename}.json", params: { token: token }

      expect(response.status).to eq(404)
    end
  end

  describe '#destroy' do
    it "removes the backup if found" do
      begin
        path = backup_path(backup_filename)
        create_backup_files(backup_filename)
        expect(File.exists?(path)).to eq(true)

        expect do
          delete "/admin/backups/#{backup_filename}.json"
        end.to change { UserHistory.where(action: UserHistory.actions[:backup_destroy]).count }.by(1)

        expect(response.status).to eq(200)
        expect(File.exists?(path)).to eq(false)
      end
    end

    it "doesn't remove the backup if not found" do
      delete "/admin/backups/#{backup_filename}.json"
      expect(response.status).to eq(404)
    end
  end

  describe '#logs' do
    it "preloads important data" do
      get "/admin/backups/logs.html"
      expect(response.status).to eq(200)

      preloaded = map_preloaded

      expect(preloaded["operations_status"].symbolize_keys).to eq(BackupRestore.operations_status)
      expect(preloaded["logs"].size).to eq(BackupRestore.logs.size)
    end
  end

  describe '#restore' do
    it "starts a restore" do
      BackupRestore.expects(:restore!).with(admin.id, filename: backup_filename, publish_to_message_bus: true, client_id: "foo")

      post "/admin/backups/#{backup_filename}/restore.json", params: { client_id: "foo" }

      expect(response.status).to eq(200)
    end
  end

  describe '#readonly' do
    it "enables readonly mode" do
      expect(Discourse.readonly_mode?).to eq(false)

      expect { put "/admin/backups/readonly.json", params: { enable: true } }
        .to change { UserHistory.where(action: UserHistory.actions[:change_readonly_mode], new_value: "t").count }.by(1)

      expect(Discourse.readonly_mode?).to eq(true)
      expect(response.status).to eq(200)
    end

    it "disables readonly mode" do
      Discourse.enable_readonly_mode(Discourse::USER_READONLY_MODE_KEY)
      expect(Discourse.readonly_mode?).to eq(true)

      expect { put "/admin/backups/readonly.json", params: { enable: false } }
        .to change { UserHistory.where(action: UserHistory.actions[:change_readonly_mode], new_value: "f").count }.by(1)

      expect(response.status).to eq(200)
      expect(Discourse.readonly_mode?).to eq(false)
    end
  end

  describe "#upload_backup_chunk" do
    describe "when filename contains invalid characters" do
      it "should raise an error" do
        ['灰色.tar.gz', '; echo \'haha\'.tar.gz'].each do |invalid_filename|
          described_class.any_instance.expects(:has_enough_space_on_disk?).returns(true)

          post "/admin/backups/upload", params: {
            resumableFilename: invalid_filename,
            resumableTotalSize: 1,
            resumableIdentifier: 'test'
          }

          expect(response.status).to eq(415)
          expect(response.body).to eq(I18n.t('backup.invalid_filename'))
        end
      end
    end

    describe "when resumableIdentifier is invalid" do
      it "should raise an error" do
        filename = 'test_site-0123456789.tar.gz'
        @paths = [backup_path(File.join('tmp', 'test', "#{filename}.part1"))]

        post "/admin/backups/upload.json", params: {
          resumableFilename: filename,
          resumableTotalSize: 1,
          resumableIdentifier: '../test',
          resumableChunkNumber: '1',
          resumableChunkSize: '1',
          resumableCurrentChunkSize: '1',
          file: fixture_file_upload(Tempfile.new)
        }

        expect(response.status).to eq(400)
      end
    end

    describe "when filename is valid" do
      it "should upload the file successfully" do
        described_class.any_instance.expects(:has_enough_space_on_disk?).returns(true)

        filename = 'test_Site-0123456789.tar.gz'
        @paths = [backup_path(File.join('tmp', 'test', "#{filename}.part1"))]

        post "/admin/backups/upload.json", params: {
          resumableFilename: filename,
          resumableTotalSize: 1,
          resumableIdentifier: 'test',
          resumableChunkNumber: '1',
          resumableChunkSize: '1',
          resumableCurrentChunkSize: '1',
          file: fixture_file_upload(Tempfile.new)
        }

        expect(response.status).to eq(200)
        expect(response.body).to eq("")
      end
    end
  end

  describe "#check_backup_chunk" do
    describe "when resumableIdentifier is invalid" do
      it "should raise an error" do
        get "/admin/backups/upload", params: {
          resumableIdentifier: "../some_file",
          resumableFilename: "test_site-0123456789.tar.gz",
          resumableChunkNumber: '1',
          resumableCurrentChunkSize: '1'
        }

        expect(response.status).to eq(400)
      end
    end
  end

  describe '#rollback' do
    it 'should rollback the restore' do
      BackupRestore.expects(:rollback!)

      post "/admin/backups/rollback.json"

      expect(response.status).to eq(200)
    end

    it 'should not allow rollback via a GET request' do
      get "/admin/backups/rollback.json"
      expect(response.status).to eq(404)
    end
  end

  describe '#cancel' do
    it "should cancel an backup" do
      BackupRestore.expects(:cancel!)

      delete "/admin/backups/cancel.json"

      expect(response.status).to eq(200)
    end

    it 'should not allow cancel via a GET request' do
      get "/admin/backups/cancel.json"
      expect(response.status).to eq(404)
    end
  end

  describe "#email" do
    it "enqueues email job" do

      # might as well test this here if we really want www.example.com
      SiteSetting.force_hostname = "www.example.com"

      create_backup_files(backup_filename)

      expect {
        put "/admin/backups/#{backup_filename}.json"
      }.to change { Jobs::DownloadBackupEmail.jobs.size }.by(1)

      job_args = Jobs::DownloadBackupEmail.jobs.last["args"].first
      expect(job_args["user_id"]).to eq(admin.id)
      expect(job_args["backup_file_path"]).to eq("http://www.example.com/admin/backups/#{backup_filename}")

      expect(response.status).to eq(200)
    end

    it "returns 404 when the backup does not exist" do
      put "/admin/backups/#{backup_filename}.json"

      expect(response).to be_not_found
    end
  end
end
