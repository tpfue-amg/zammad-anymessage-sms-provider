# Copyright (C) 2026 AnyMessage GmbH, https://www.anymessage.cloud/en

# Prepended to CommunicateSmsJob (see config/initializers/any_message_sms.rb).
# Stores the AMG messageIds of a successful delivery on the article, so incoming
# delivery reports can be matched. Uses the job's own save in log_success to avoid
# overwriting the article preferences with a second, concurrent save.
module Channel::Driver::Sms::AnyMessage::CommunicateSmsJobExtension
  def perform(article_id)
    Channel::Driver::Sms::AnyMessage::MessageIdCollector.collect { super }
  end

  private

  def log_success(article)
    message_ids = Channel::Driver::Sms::AnyMessage::MessageIdCollector.ids

    if message_ids.present?
      article.preferences['any_message'] ||= {}
      article.preferences['any_message']['message_ids'] = message_ids
      article.message_id = message_ids.first if article.message_id.blank?
    end

    super
  end
end
