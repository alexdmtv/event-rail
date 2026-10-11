# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :name, :address, :phone
]

# The request parameters whose values the event log shows; every other value is written as
# [FILTERED], so a field added later stays out of the log until it is named here. The list above
# still guards what Rails writes elsewhere.
Rails.application.config.platform.logged_params = %w[ id cart_id order_id sku quantity ]
