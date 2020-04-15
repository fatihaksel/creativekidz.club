# frozen_string_literal: true

class Poll < ActiveRecord::Base
  # because we want to use the 'type' column and don't want to use STI
  self.inheritance_column = nil

  belongs_to :post

  has_many :poll_options, -> { order(:id) }, dependent: :destroy
  has_many :poll_votes

  enum type: {
    regular: 0,
    multiple: 1,
    number: 2,
  }

  enum status: {
    open: 0,
    closed: 1,
  }

  enum results: {
    always: 0,
    on_vote: 1,
    on_close: 2,
    staff_only: 3,
  }

  enum visibility: {
    secret: 0,
    everyone: 1,
  }

  enum chart_type: {
    bar: 0,
    pie: 1
  }

  validates :min, numericality: { allow_nil: true, only_integer: true, greater_than_or_equal_to: 0 }
  validates :max, numericality: { allow_nil: true, only_integer: true, greater_than: 0 }
  validates :step, numericality: { allow_nil: true, only_integer: true, greater_than: 0 }

  def is_closed?
    closed? || (close_at && close_at <= Time.zone.now)
  end

  def can_see_results?(user)
    return !!user&.staff? if staff_only?
    !!(always? || (on_vote? && (is_me?(user) || has_voted?(user))) || is_closed?)
  end

  def is_me?(user)
    user && post.user&.id == user&.id
  end

  def has_voted?(user)
    user&.id && poll_votes.any? { |v| v.user_id == user.id }
  end

  def can_see_voters?(user)
    everyone? && can_see_results?(user)
  end
end

# == Schema Information
#
# Table name: polls
#
#  id               :bigint           not null, primary key
#  post_id          :bigint
#  name             :string           default("poll"), not null
#  close_at         :datetime
#  type             :integer          default("regular"), not null
#  status           :integer          default("open"), not null
#  results          :integer          default("always"), not null
#  visibility       :integer          default("secret"), not null
#  min              :integer
#  max              :integer
#  step             :integer
#  anonymous_voters :integer
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  chart_type       :integer          default("bar"), not null
#  groups           :string
#
# Indexes
#
#  index_polls_on_post_id           (post_id)
#  index_polls_on_post_id_and_name  (post_id,name) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (post_id => posts.id)
#
