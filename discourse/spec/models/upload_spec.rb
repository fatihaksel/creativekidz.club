# frozen_string_literal: true

require 'rails_helper'

describe Upload do

  let(:upload) { build(:upload) }

  let(:user_id) { 1 }

  let(:image_filename) { "logo.png" }
  let(:image) { file_from_fixtures(image_filename) }

  let(:image_svg_filename) { "image.svg" }
  let(:image_svg) { file_from_fixtures(image_svg_filename) }

  let(:huge_image_filename) { "huge.jpg" }
  let(:huge_image) { file_from_fixtures(huge_image_filename) }

  let(:attachment_path) { __FILE__ }
  let(:attachment) { File.new(attachment_path) }

  context ".create_thumbnail!" do

    it "does not create a thumbnail when disabled" do
      SiteSetting.create_thumbnails = false
      OptimizedImage.expects(:create_for).never
      upload.create_thumbnail!(100, 100)
    end

    it "creates a thumbnail" do
      upload = Fabricate(:upload)
      thumbnail = Fabricate(:optimized_image, upload: upload)
      SiteSetting.expects(:create_thumbnails?).returns(true)
      OptimizedImage.expects(:create_for).returns(thumbnail)
      upload.create_thumbnail!(100, 100)
      upload.reload
      expect(upload.optimized_images.count).to eq(1)
    end
  end

  it "supports <style> element in SVG" do
    SiteSetting.authorized_extensions = "svg"

    upload = UploadCreator.new(image_svg, image_svg_filename).create_for(user_id)
    expect(upload.valid?).to eq(true)

    path = Discourse.store.path_for(upload)
    expect(File.read(path)).to match(/<style>/)
  end

  it "can reconstruct dimensions on demand" do
    upload = UploadCreator.new(huge_image, "image.png").create_for(user_id)

    upload.update_columns(width: nil, height: nil, thumbnail_width: nil, thumbnail_height: nil)

    upload = Upload.find(upload.id)

    expect(upload.width).to eq(64250)
    expect(upload.height).to eq(64250)

    upload.reload
    expect(upload.read_attribute(:width)).to eq(64250)

    upload.update_columns(width: nil, height: nil, thumbnail_width: nil, thumbnail_height: nil)

    expect(upload.thumbnail_width).to eq(500)
    expect(upload.thumbnail_height).to eq(500)
  end

  it "dimension calculation returns nil on missing image" do
    upload = UploadCreator.new(huge_image, "image.png").create_for(user_id)
    upload.update_columns(width: nil, height: nil, thumbnail_width: nil, thumbnail_height: nil)

    missing_url = "wrong_folder#{upload.url}"
    upload.update_columns(url: missing_url)
    expect(upload.thumbnail_height).to eq(nil)
    expect(upload.thumbnail_width).to eq(nil)
  end

  it "extracts file extension" do
    created_upload = UploadCreator.new(image, image_filename).create_for(user_id)
    expect(created_upload.extension).to eq("png")
  end

  it "should create an invalid upload when the filename is blank" do
    SiteSetting.authorized_extensions = "*"
    created_upload = UploadCreator.new(attachment, nil).create_for(user_id)
    expect(created_upload.valid?).to eq(false)
  end

  context ".extract_url" do
    let(:url) { 'https://example.com/uploads/default/original/1X/d1c2d40ab994e8410c.png' }

    it 'should return the right part of url' do
      expect(Upload.extract_url(url).to_s).to eq('/original/1X/d1c2d40ab994e8410c.png')
    end
  end

  context ".get_from_url" do
    let(:sha1) { "10f73034616a796dfd70177dc54b6def44c4ba6f" }
    let(:upload) { Fabricate(:upload, sha1: sha1) }

    it "works when the file has been uploaded" do
      expect(Upload.get_from_url(upload.url)).to eq(upload)
    end

    describe 'for an extensionless url' do
      before do
        upload.update!(url: upload.url.sub('.png', ''))
        upload.reload
      end

      it 'should return the right upload' do
        expect(Upload.get_from_url(upload.url)).to eq(upload)
      end
    end

    it "should return the right upload as long as the upload's URL matches" do
      upload.update!(url: "/uploads/default/12345/971308e535305c51.png")

      expect(Upload.get_from_url(upload.url)).to eq(upload)

      expect(Upload.get_from_url("/uploads/default/123131/971308e535305c51.png"))
        .to eq(nil)
    end

    describe 'for a url a tree' do
      before do
        upload.update!(url:
          Discourse.store.get_path_for(
            "original",
            16001,
            upload.sha1,
            ".#{upload.extension}"
          )
        )
      end

      it 'should return the right upload' do
        expect(Upload.get_from_url(upload.url)).to eq(upload)
      end
    end

    it "works when using a cdn" do
      begin
        original_asset_host = Rails.configuration.action_controller.asset_host
        Rails.configuration.action_controller.asset_host = 'http://my.cdn.com'

        expect(Upload.get_from_url(
          URI.join("http://my.cdn.com", upload.url).to_s
        )).to eq(upload)
      ensure
        Rails.configuration.action_controller.asset_host = original_asset_host
      end
    end

    it "should return the right upload when using the full URL" do
      expect(Upload.get_from_url(
        URI.join("http://discourse.some.com:3000/", upload.url).to_s
      )).to eq(upload)
    end

    it "doesn't blow up with an invalid URI" do
      expect { Upload.get_from_url("http://ip:port/index.html") }.not_to raise_error
      expect { Upload.get_from_url("mailto:admin%40example.com") }.not_to raise_error
      expect { Upload.get_from_url("mailto:example") }.not_to raise_error
    end

    describe "s3 store" do
      let(:upload) { Fabricate(:upload_s3) }
      let(:path) { upload.url.sub(SiteSetting.Upload.s3_base_url, '') }

      before do
        SiteSetting.enable_s3_uploads = true
        SiteSetting.s3_upload_bucket = "s3-upload-bucket"
        SiteSetting.s3_access_key_id = "some key"
        SiteSetting.s3_secret_access_key = "some secret key"
      end

      it "should return the right upload when using base url (not CDN) for s3" do
        upload
        expect(Upload.get_from_url(upload.url)).to eq(upload)
      end

      describe 'when using a cdn' do
        let(:s3_cdn_url) { 'https://mycdn.slowly.net' }

        before do
          SiteSetting.s3_cdn_url = s3_cdn_url
        end

        it "should return the right upload" do
          upload
          expect(Upload.get_from_url(URI.join(s3_cdn_url, path).to_s)).to eq(upload)
        end

        describe 'when upload bucket contains subfolder' do
          before do
            SiteSetting.s3_upload_bucket = "s3-upload-bucket/path/path2"
          end

          it "should return the right upload" do
            upload
            expect(Upload.get_from_url(URI.join(s3_cdn_url, path).to_s)).to eq(upload)
          end
        end
      end

      it "should return the right upload when using one CDN for both s3 and assets" do
        begin
          original_asset_host = Rails.configuration.action_controller.asset_host
          cdn_url = 'http://my.cdn.com'
          Rails.configuration.action_controller.asset_host = cdn_url
          SiteSetting.s3_cdn_url = cdn_url
          upload

          expect(Upload.get_from_url(
            URI.join(cdn_url, path).to_s
          )).to eq(upload)
        ensure
          Rails.configuration.action_controller.asset_host = original_asset_host
        end
      end
    end
  end

  describe '.generate_digest' do
    it "should return the right digest" do
      expect(Upload.generate_digest(image.path)).to eq('bc975735dfc6409c1c2aa5ebf2239949bcbdbd65')
    end
  end

  describe '.short_url' do
    it "should generate a correct short url" do
      upload = Upload.new(sha1: 'bda2c513e1da04f7b4e99230851ea2aafeb8cc4e', extension: 'png')
      expect(upload.short_url).to eq('upload://r3AYqESanERjladb4vBB7VsMBm6.png')

      upload.extension = nil
      expect(upload.short_url).to eq('upload://r3AYqESanERjladb4vBB7VsMBm6')
    end
  end

  describe '.sha1_from_short_url' do
    it "should be able to look up sha1" do
      sha1 = 'bda2c513e1da04f7b4e99230851ea2aafeb8cc4e'

      expect(Upload.sha1_from_short_url('upload://r3AYqESanERjladb4vBB7VsMBm6.png')).to eq(sha1)
      expect(Upload.sha1_from_short_url('upload://r3AYqESanERjladb4vBB7VsMBm6')).to eq(sha1)
      expect(Upload.sha1_from_short_url('r3AYqESanERjladb4vBB7VsMBm6')).to eq(sha1)
    end

    it "should be able to look up sha1 even with leading zeros" do
      sha1 = '0000c513e1da04f7b4e99230851ea2aafeb8cc4e'
      expect(Upload.sha1_from_short_url('upload://1Eg9p8rrCURq4T3a6iJUk0ri6.png')).to eq(sha1)
    end
  end

  describe '#base62_sha1' do
    it 'should return the right value' do
      upload.update!(sha1: "0000c513e1da04f7b4e99230851ea2aafeb8cc4e")
      expect(upload.base62_sha1).to eq("1Eg9p8rrCURq4T3a6iJUk0ri6")
    end
  end

  describe '.sha1_from_short_path' do
    it "should be able to lookup sha1" do
      path = "/uploads/short-url/3UjQ4jHoyeoQndk5y3qHzm3QVTQ.png"
      sha1 = "1b6453892473a467d07372d45eb05abc2031647a"

      expect(Upload.sha1_from_short_path(path)).to eq(sha1)
      expect(Upload.sha1_from_short_path(path.sub(".png", ""))).to eq(sha1)
    end
  end

  describe '#to_s' do
    it 'should return the right value' do
      expect(upload.to_s).to eq(upload.url)
    end
  end

  describe '.migrate_to_new_scheme' do
    it 'should not migrate system uploads' do
      SiteSetting.migrate_to_new_scheme = true

      expect { Upload.migrate_to_new_scheme }
        .to_not change { Upload.pluck(:url) }
    end
  end

  describe ".consider_for_reuse" do
    let(:post) { Fabricate(:post) }
    let(:upload) { Fabricate(:upload) }

    it "returns nil when the provided upload is blank" do
      expect(Upload.consider_for_reuse(nil, post)).to eq(nil)
    end

    it "returns the upload when secure media is disabled" do
      expect(Upload.consider_for_reuse(upload, post)).to eq(upload)
    end

    context "when secure media enabled" do
      before do
        enable_secure_media
      end

      context "when the upload access control post is != to the provided post" do
        before do
          upload.update(access_control_post_id: Fabricate(:post).id)
        end

        it "returns nil" do
          expect(Upload.consider_for_reuse(upload, post)).to eq(nil)
        end
      end

      context "when the upload original_sha1 is blank (pre-secure-media upload)" do
        before do
          upload.update(original_sha1: nil, access_control_post: post)
        end

        it "returns nil" do
          expect(Upload.consider_for_reuse(upload, post)).to eq(nil)
        end
      end

      context "when the upload original_sha1 is present and access control post is correct" do
        let(:upload) { Fabricate(:secure_upload_s3, access_control_post: post) }

        it "returns the upload" do
          expect(Upload.consider_for_reuse(upload, post)).to eq(upload)
        end
      end
    end
  end

  describe '.update_secure_status' do
    it "respects the secure_override_value parameter if provided" do
      upload.update!(secure: true)

      upload.update_secure_status(secure_override_value: true)

      expect(upload.secure).to eq(true)

      upload.update_secure_status(secure_override_value: false)

      expect(upload.secure).to eq(false)
    end

    it 'marks a local upload as not secure with default settings' do
      upload.update!(secure: true)
      expect { upload.update_secure_status }
        .to change { upload.secure }

      expect(upload.secure).to eq(false)
    end

    it 'marks a local attachment as secure if secure media enabled' do
      SiteSetting.authorized_extensions = "pdf"
      upload.update!(original_filename: "small.pdf", extension: "pdf", secure: false, access_control_post: Fabricate(:private_message_post))
      enable_secure_media

      expect { upload.update_secure_status }
        .to change { upload.secure }

      expect(upload.secure).to eq(true)
    end

    it 'marks a local attachment as not secure if secure media enabled' do
      SiteSetting.authorized_extensions = "pdf"
      upload.update!(original_filename: "small.pdf", extension: "pdf", secure: true)

      expect { upload.update_secure_status }
        .to change { upload.secure }

      expect(upload.secure).to eq(false)
    end

    it 'does not change secure status of a non-attachment when prevent_anons_from_downloading_files is enabled by itself' do
      SiteSetting.prevent_anons_from_downloading_files = true
      SiteSetting.authorized_extensions = "mp4"
      upload.update!(original_filename: "small.mp4", extension: "mp4")

      expect { upload.update_secure_status }
        .not_to change { upload.secure }

      expect(upload.secure).to eq(false)
    end

    context "secure media enabled" do
      before do
        enable_secure_media
      end

      it 'does not mark an image upload as not secure when there is no access control post id, to avoid unintentional exposure' do
        upload.update!(secure: true)
        upload.update_secure_status
        expect(upload.secure).to eq(true)
      end

      it 'marks the upload as not secure if its access control post is a public post' do
        upload.update!(secure: true, access_control_post: Fabricate(:post))
        upload.update_secure_status
        expect(upload.secure).to eq(false)
      end

      it 'leaves the upload as secure if its access control post is a PM post' do
        upload.update!(secure: true, access_control_post: Fabricate(:private_message_post))
        upload.update_secure_status
        expect(upload.secure).to eq(true)
      end

      it 'marks an image upload as secure if login_required is enabled' do
        SiteSetting.login_required = true
        upload.update!(secure: false)

        expect { upload.update_secure_status }
          .to change { upload.secure }

        expect(upload.reload.secure).to eq(true)
      end

      it 'does not mark an upload used for a custom emoji as secure' do
        SiteSetting.login_required = true
        upload.update!(secure: false)
        CustomEmoji.create(name: 'meme', upload: upload)
        upload.update_secure_status
        expect(upload.reload.secure).to eq(false)
      end

      it 'does not mark an upload whose origin matches a regular emoji as secure (sometimes emojis are downloaded in pull_hotlinked_images)' do
        SiteSetting.login_required = true
        falafel = Emoji.all.find { |e| e.url == '/images/emoji/twitter/falafel.png?v=9' }
        upload.update!(secure: false, origin: "http://localhost:3000#{falafel.url}")
        upload.update_secure_status
        expect(upload.reload.secure).to eq(false)
      end

      it 'does not mark any upload with origin containing images/emoji in the URL' do
        SiteSetting.login_required = true
        upload.update!(secure: false, origin: "http://localhost:3000/images/emoji/test.png")
        upload.update_secure_status
        expect(upload.reload.secure).to eq(false)
      end
    end
  end

  describe '.reset_unknown_extensions!' do
    it 'should reset the extension of uploads when it is "unknown"' do
      upload1 = Fabricate(:upload, extension: "unknown")
      upload2 = Fabricate(:upload, extension: "png")

      Upload.reset_unknown_extensions!

      expect(upload1.reload.extension).to eq(nil)
      expect(upload2.reload.extension).to eq("png")
    end
  end

  def enable_secure_media
    SiteSetting.enable_s3_uploads = true
    SiteSetting.s3_upload_bucket = "s3-upload-bucket"
    SiteSetting.s3_access_key_id = "some key"
    SiteSetting.s3_secret_access_key = "some secrets3_region key"
    SiteSetting.secure_media = true

    stub_request(:head, "https://#{SiteSetting.s3_upload_bucket}.s3.amazonaws.com/")

    stub_request(
      :put,
      "https://#{SiteSetting.s3_upload_bucket}.s3.amazonaws.com/original/1X/#{upload.sha1}.#{upload.extension}?acl"
    )
  end
end
