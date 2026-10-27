# Copyright (C) 2026 AnyMessage GmbH, https://www.anymessage.cloud/en

# CommunicateSmsJob ignores the return value of Channel#deliver, so the AMG messageIds
# are collected per thread while the job runs and attached to the article on success
# (see CommunicateSmsJobExtension). Required to match delivery reports to articles.
module Channel::Driver::Sms::AnyMessage::MessageIdCollector
  KEY = :any_message_sms_message_ids

  def self.collect
    previous = Thread.current[KEY]
    Thread.current[KEY] = []
    yield
  ensure
    Thread.current[KEY] = previous
  end

  def self.add(message_id)
    return if message_id.blank? || Thread.current[KEY].nil?

    Thread.current[KEY] << message_id
  end

  def self.ids
    Array(Thread.current[KEY]).dup
  end
end
