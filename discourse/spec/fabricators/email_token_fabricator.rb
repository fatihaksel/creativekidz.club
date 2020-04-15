# frozen_string_literal: true

Fabricator(:email_token) do
  user
  email { |attrs| attrs[:user].email }
end
