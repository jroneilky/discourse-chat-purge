# name: discourse-chat-purge
# about: Hard-deletes chat messages 5 minutes after soft-deletion
# version: 0.2
# authors: Admin

after_initialize do
  module ::Jobs
    class PurgeDeletedChatMessages < ::Jobs::Scheduled
      every 1.minute

      def execute(args)
        chat_model = defined?(::Chat::Message) ? ::Chat::Message : (defined?(::ChatMessage) ? ::ChatMessage : nil)
        return unless chat_model

        cutoff = 5.minutes.ago
        soft_deleted = chat_model
          .with_deleted
          .where.not(deleted_at: nil)
          .where("deleted_at < ?", cutoff)

        count = 0
        soft_deleted.find_each do |message|
          begin
            message.destroy!
            count += 1
          rescue => e
            Rails.logger.error("[chat-purge] Failed to hard-delete message #{message.id}: #{e.message}")
          end
        end

        Rails.logger.info("[chat-purge] Hard-deleted #{count} messages.") if count > 0
      end
    end
  end
end
