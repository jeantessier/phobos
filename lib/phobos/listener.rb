module Phobos
  class Listener
    include Phobos::Instrumentation

    attr_reader :group_id, :topic, :id

    def initialize(handler_class, group_id:, topic:)
      @id = SecureRandom.hex[0...6]
      @handler_class = handler_class
      @group_id = group_id
      @topic = topic
      @kafka_client = Phobos.create_kafka_client
    end

    def start
      @signal_to_stop = false
      instrument('listener.start', listener_metadata) do
        @handler = @handler_class.new
        @consumer = @kafka_client.consumer(group_id: group_id)
        @consumer.subscribe(topic)
      end

      @consumer.each_batch do |batch|
        batch_metadata = {
          batch_size: batch.messages.count,
          partition: batch.partition,
          offset_lag: batch.offset_lag,
          highwater_mark_offset: batch.highwater_mark_offset
        }.merge(listener_metadata)

        instrument('listener.process_batch', batch_metadata) { process_batch(batch) }
      end

    rescue Phobos::AbortError
      instrument('listener.retry_aborted', listener_metadata) do
        Phobos.logger.info do
          {message: 'Retry loop aborted, listener is shutting down'}.merge(listener_metadata)
        end
      end
    end

    def stop
      instrument('listener.stop') do
        Phobos.logger.info { Hash(message: 'Listener stopping').merge(listener_metadata) }
        @consumer.stop
        @kafka_client.close
        @signal_to_stop = true
      end
    end

    private

    def listener_metadata
      { listener_id: id, group_id: group_id, topic: topic }
    end

    def process_batch(batch)
      batch.messages.each do |message|
        backoff = Phobos.create_exponential_backoff
        partition = batch.partition
        metadata = {
          key: message.key,
          partition: partition,
          offset: message.offset,
          retry_count: 0
        }.merge(listener_metadata)

        begin
          instrument('listener.process_message', metadata) { process_message(message, metadata) }
          break
        rescue Exception => e
          retry_count = metadata[:retry_count]
          interval = backoff.interval_at(retry_count).round(2)

          error = {
            exception_class: e.class.name,
            exception_message: e.message,
            backtrace: e.backtrace,
            waiting_time: interval,
            listener_id: id
          }

          instrument('listener.retry_handler_error', error.merge(metadata)) do
            Phobos.logger.error do
              {message: "error processing message, waiting #{interval}s"}.merge(error).merge(metadata)
            end

            sleep interval
            metadata.merge!(retry_count: retry_count + 1)
          end

          raise Phobos::AbortError if @signal_to_stop
          retry
        end
      end
    end

    def process_message(message, metadata)
      @handler.consume(message.value, metadata)
    end

  end
end
