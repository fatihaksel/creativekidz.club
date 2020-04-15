# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DiscourseNarrativeBot::CertificateGenerator do
  let(:user) { Fabricate(:user) }
  let(:avatar_url) { 'http://test.localhost/cdn/avatar.png' }
  let(:date) { "2017-00-10" }

  describe 'when an invalid date is given' do
    it 'should default to the current date' do
      expect { described_class.new(user, date, avatar_url) }.to_not raise_error
    end
  end

  describe '#logo_group' do
    describe 'when SiteSetting.site_logo_small_url is blank' do
      before do
        SiteSetting.logo_small = ''
        SiteSetting.logo_small_url = ''
      end

      it 'should not try to fetch a image' do
        expect(described_class.new(user, date, avatar_url).send(:logo_group, 1, 1, 1))
          .to eq(nil)
      end
    end
  end
end
