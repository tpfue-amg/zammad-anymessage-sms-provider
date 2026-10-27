# Copyright (C) 2026 AnyMessage GmbH, https://www.anymessage.cloud/en

# Maps the AnyMessage inbound SMS (MO) webhook payload to the attributes the driver needs.
#
# The layout follows a real AMG MO push, see spec/fixtures/files/any_message/inbound.json.
# Each entry is a list of candidate paths, the first non-blank value wins.
#
# Note: AMG does not send the recipient number yet, only recipient.integrationUuid.
# AnyMessage will add it later; recipient.msisdn is assumed, analogous to sender.msisdn.
class Channel::Driver::Sms::AnyMessage::InboundMessage
  FIELD_PATHS = {
    from:        [%w[sender msisdn]],
    to:          [%w[recipient msisdn]],
    text:        [%w[content text]],
    message_id:  [%w[messageId]],
    received_at: [%w[messageTimestamp]],
  }.freeze

  REQUIRED_FIELDS = %i[from text].freeze

  attr_reader(*FIELD_PATHS.keys)

  def initialize(params)
    params = params.to_h.with_indifferent_access

    FIELD_PATHS.each do |field, paths|
      instance_variable_set(:"@#{field}", lookup(params, paths))
    end

    @from = normalize_number(@from)
    @to   = normalize_number(@to)

    validate!
  end

  private

  def lookup(params, paths)
    paths.each do |path|
      value = params.dig(*path)
      return value.to_s if value.present?
    end

    nil
  end

  # Zammad stores mobile numbers with a leading '+', AMG sends digits only.
  def normalize_number(number)
    return if number.blank?

    # keep alphanumeric senders untouched
    return number.to_s if !number.to_s.match?(%r{\A[\d\s+\-()/]+\z})

    "+#{number.to_s.gsub(%r{\D}, '').sub(%r{\A00}, '')}"
  end

  def validate!
    missing = REQUIRED_FIELDS.select { |field| public_send(field).blank? }
    return if missing.empty?

    raise Exceptions::UnprocessableContent, "AnyMessage inbound SMS is missing: #{missing.join(', ')}"
  end
end
