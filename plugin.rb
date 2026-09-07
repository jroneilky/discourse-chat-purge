# frozen_string_literal: true

# name: discourse-content-purge
# about: Permanently deletes soft-deleted chat messages after a few minutes, and soft-deleted posts (including personal messages) after 24 hours, without ever cascading into a topic's replies.
# version: 1.2
# authors: Admin
# required_version: 2.7.0

enabled_site_setting :content_purge_enabled

after_initialize do
  module ::DiscourseContentPurge
    LOG_PREFIX = "[content-purge]"

    # Topics whose first post must never be touched (seeded legal/policy topics).
    # respond_to? guards against a setting being renamed or removed upstream.
    def self.protected_topic_ids
      %i[tos_topic_id privacy_topic_id guidelines_topic_id]
        .filter_map { |key| SiteSetting.respond_to?(key) ? SiteSetting.public_send(key) : nil }
        .map(&:to_i)
        .select(&:positive?)
    end
  end

  module ::Jobs
    # ---------------------------------------------------------------------
    # CHAT MESSAGES -- the FAST timeline (minutes).
    # Covers every chat message, including those in direct message channels.
    # ---------------------------------------------------------------------
    class ContentPurgeChatMessages < ::Jobs::Scheduled
      every 1.minute

      def execute(args)
        return unless SiteSetting.content_purge_enabled
        return unless SiteSetting.respond_to?(:chat_enabled) && SiteSetting.chat_enabled
        return unless defined?(::Chat::Message) && defined?(::Chat::MessageDestroyer)

        cutoff = SiteSetting.content_purge_chat_messages_after_minutes.minutes.ago

        ids =
          ::Chat::Message
            .with_deleted
            .where.not(deleted_at: nil)
            .where("chat_messages.deleted_at < ?", cutoff)
            .order(:deleted_at)
            .limit(SiteSetting.content_purge_chat_messages_batch_size)
            .pluck(:id)
        return if ids.empty?

        purged = 0

        # Chunked so one un-destroyable row can't block the whole backlog;
        # a failed chunk is retried one message at a time and the offender
        # is logged by id.
        ids.each_slice(100) do |slice|
          begin
            purged += purge(slice)
          rescue => e
            Rails.logger.warn(
              "#{::DiscourseContentPurge::LOG_PREFIX} chunk failed (#{e.class}: #{e.message}); retrying individually",
            )
            slice.each do |id|
              begin
                purged += purge([id])
              rescue => inner
                Rails.logger.error(
                  "#{::DiscourseContentPurge::LOG_PREFIX} could not hard-delete chat message #{id}: #{inner.class}: #{inner.message}",
                )
              end
            end
          end
        end

        if purged > 0
          Rails.logger.info("#{::DiscourseContentPurge::LOG_PREFIX} hard-deleted #{purged} chat message(s)")
        end
      end

      private

      # Core's own destroyer: resets channel last_message_ids, resets per-user
      # last_read_message_id, and deletes chat flags/reviewables. Delegating
      # means Discourse maintains the cleanup list, not us.
      def purge(ids)
        ::Chat::MessageDestroyer.new.destroy_in_batches(
          ::Chat::Message.with_deleted.where(id: ids),
          batch_size: ids.size,
        )
        ids.size
      end
    end

    # ---------------------------------------------------------------------
    # POSTS -- the SLOW timeline (hours). Personal messages are posts, so
    # they run on THIS clock, never the chat one.
    # ---------------------------------------------------------------------
    class ContentPurgePosts < ::Jobs::Scheduled
      # Every 15 min so a post crossing the threshold is purged promptly
      # rather than up to an hour late.
      every 15.minutes

      def execute(args)
        return unless SiteSetting.content_purge_enabled

        cutoff = SiteSetting.content_purge_posts_after_hours.hours.ago
        batch_size = SiteSetting.content_purge_posts_batch_size
        scope = candidate_scope(cutoff)

        # PostDestroyer(force_destroy: true) on post_number 1 destroys EVERY
        # post in the topic (including non-deleted ones) and then the topic.
        # So a first post is only eligible when it is the only post that has
        # ever existed in its topic -- counted across ALL rows, deleted or not.
        first_post_ids =
          scope
            .where(post_number: 1)
            .where("(SELECT COUNT(*) FROM posts p2 WHERE p2.topic_id = posts.topic_id) = 1")
            .order(deleted_at: :asc, id: :asc)
            .limit(batch_size)
            .pluck(:id)

        # Opt-in: when the TOPIC itself was deleted, purging it in full
        # (first post + replies) is the intended outcome, not a surprise cascade.
        if SiteSetting.content_purge_posts_in_deleted_topics && first_post_ids.length < batch_size
          first_post_ids +=
            scope
              .where(post_number: 1)
              .where.not(topics: { deleted_at: nil })
              .where.not(id: first_post_ids)
              .order(deleted_at: :asc, id: :asc)
              .limit(batch_size - first_post_ids.length)
              .pluck(:id)
        end

        remaining = batch_size - first_post_ids.length
        reply_ids =
          if remaining.positive?
            scope
              .where.not(post_number: 1)
              .order(deleted_at: :asc, id: :asc)
              .limit(remaining)
              .pluck(:id)
          else
            []
          end

        count = 0

        (first_post_ids + reply_ids).each do |post_id|
          begin
            post = Post.with_deleted.find_by(id: post_id)
            next unless post
            next if post.deleted_at.blank? || post.deleted_at >= cutoff

            topic = Topic.with_deleted.find_by(id: post.topic_id)
            next unless topic
            next if protected_topic?(topic)

            # Re-check the no-cascade guarantee immediately before destroying,
            # in case a reply landed since the batch was queried.
            if post.is_first_post?
              siblings =
                Post.with_deleted.where(topic_id: topic.id).where.not(id: post.id).exists?
              if siblings
                next unless SiteSetting.content_purge_posts_in_deleted_topics &&
                  topic.deleted_at.present?
              end
            end

            PostDestroyer.new(
              Discourse.system_user,
              post,
              context:
                "Automatically purged #{SiteSetting.content_purge_posts_after_hours}h after deletion",
              force_destroy: true,
            ).destroy

            count += 1
          rescue => e
            Rails.logger.error(
              "#{::DiscourseContentPurge::LOG_PREFIX} could not permanently delete post #{post_id}: #{e.class}: #{e.message}",
            )
          end
        end

        if count > 0
          Rails.logger.info("#{::DiscourseContentPurge::LOG_PREFIX} permanently deleted #{count} post(s)")
        end
      end

      private

      def candidate_scope(cutoff)
        scope =
          Post
            .with_deleted
            .where.not(deleted_at: nil)
            .where("posts.deleted_at < ?", cutoff)
            .joins("INNER JOIN topics ON topics.id = posts.topic_id")
            # Category "about" topics: their first post defines the category.
            .where("NOT EXISTS (SELECT 1 FROM categories c WHERE c.topic_id = posts.topic_id)")

        protected_ids = ::DiscourseContentPurge.protected_topic_ids
        scope = scope.where.not(topic_id: protected_ids) if protected_ids.any?

        unless SiteSetting.content_purge_posts_in_private_messages
          scope = scope.where.not(topics: { archetype: Archetype.private_message })
        end

        scope
      end

      def protected_topic?(topic)
        return true if ::DiscourseContentPurge.protected_topic_ids.include?(topic.id)
        return true if Category.exists?(topic_id: topic.id)
        if topic.private_message? && !SiteSetting.content_purge_posts_in_private_messages
          return true
        end
        false
      end
    end
  end
end
