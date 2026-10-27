# Copyright (C) 2026 AnyMessage GmbH, https://www.anymessage.cloud/en

# Processes an AnyMessage delivery report (DLR) and updates the delivery status of the
# matching outgoing SMS article.
#
# AMG pushes DLRs as GET query parameters, for example:
#   ?message_id=sms-6f61...&submit_date=2026-10-09%2008%3A58&done_date=2026-10-09%2008%3A58
#   &status_code=1&status=enroute&error_code=0&error=no%20error&type=sms&submitted=001&delivered=001&text=
# Each FIELD_PATHS entry is a list of candidate paths, the first non-blank value wins.
# `status` holds the numeric code, or the status name if no code is sent.
class Channel::Driver::Sms::AnyMessage::DeliveryReport
  FIELD_PATHS = {
    message_id: [%w[message_id], %w[messageId], %w[msgId], %w[id]],
    status:     [%w[status_code], %w[statusCode], %w[status]],
    error_code: [%w[error_code], %w[errorCode]],
    error:      [%w[error]],
    done_at:    [%w[done_date], %w[doneDate], %w[done]],
  }.freeze

  # Status codes as documented by AnyMessage (known).
  STATUSES = {
    0 => 'scheduled',
    1 => 'enroute',
    2 => 'delivered',
    3 => 'expired',
    4 => 'deleted',
    5 => 'undeliverable',
    6 => 'accepted',
    7 => 'unknown',
    8 => 'rejected',
    9 => 'skipped',
  }.freeze

  FINAL_STATUSES   = [2, 3, 4, 5, 7, 8, 9].freeze
  SUCCESS_STATUSES = [2].freeze

  attr_reader(*FIELD_PATHS.keys)

  def initialize(params)
    params = params.to_h.with_indifferent_access

    FIELD_PATHS.each do |field, paths|
      instance_variable_set(:"@#{field}", lookup(params, paths))
    end

    raise Exceptions::UnprocessableContent, 'AnyMessage delivery report is missing: message_id' if message_id.blank?
    raise Exceptions::UnprocessableContent, 'AnyMessage delivery report is missing: status_code' if status.blank?
  end

  def status_code
    Integer(status, exception: false) || STATUSES.key(status.downcase)
  end

  def status_name
    STATUSES.fetch(status_code, "status #{status}")
  end

  def final?
    FINAL_STATUSES.include?(status_code)
  end

  def success?
    SUCCESS_STATUSES.include?(status_code)
  end

  # Returns the updated article, or nil if no article belongs to the messageId
  # (e.g. the DLR arrived before CommunicateSmsJob stored the messageId).
  def process!
    article = find_article
    if !article
      Rails.logger.info "AnyMessage delivery report for unknown messageId #{message_id}"
      return
    end

    UserInfo.ensure_current_user_id do
      update_article(article)
    end

    article
  end

  private

  def lookup(params, paths)
    paths.each do |path|
      value = params.dig(*path)
      return value.to_s if value.present?
    end

    nil
  end

  def find_article
    article = Ticket::Article.find_by(message_id_md5: Digest::MD5.hexdigest(message_id))
    return article if article

    # additional recipients of a notification article are only stored in the preferences
    Ticket::Article
      .where('preferences LIKE ?', "%#{Ticket::Article.sanitize_sql_like(message_id)}%")
      .order(id: :desc)
      .limit(5)
      .find { |candidate| Array(candidate.preferences.dig('any_message', 'message_ids')).include?(message_id) }
  end

  def update_article(article)
    article.preferences['any_message'] ||= {}
    article.preferences['any_message']['delivery_reports'] ||= {}
    article.preferences['any_message']['delivery_reports'][message_id] = {
      'status'      => status_code,
      'status_name' => status_name,
      'error_code'  => error_code,
      'error'       => error,
      'done_at'     => done_at,
      'received_at' => Time.zone.now,
    }

    apply_delivery_status(article) if final?

    article.save!
  end

  # Multiple recipients (notifications) share one article: fail as soon as one recipient
  # failed, succeed only once all known messageIds are delivered.
  def apply_delivery_status(article)
    reports     = article.preferences['any_message']['delivery_reports']
    message_ids = Array(article.preferences['any_message']['message_ids']).presence || [message_id]

    if !success?
      article.preferences['delivery_status']         = 'fail'
      article.preferences['delivery_status_message'] = "AnyMessage: #{status_name}#{" (#{error})" if error.present? && error != 'no error'}"
    elsif message_ids.all? { |id| SUCCESS_STATUSES.include?(reports.dig(id, 'status')) }
      article.preferences['delivery_status']         = 'success'
      article.preferences['delivery_status_message'] = nil
    end

    article.preferences['delivery_status_date'] = Time.zone.now
  end
end
