class Assistant::Responder
  # Maximum number of follow-up function call rounds to prevent runaway LLM
  # spend. Some providers (e.g. DeepSeek) request tools across multiple turns
  # instead of batching them in a single response like OpenAI does.
  MAX_FOLLOW_UP_ROUNDS = 3

  def initialize(message:, instructions:, function_tool_caller:, llm:)
    @message = message
    @instructions = instructions
    @function_tool_caller = function_tool_caller
    @llm = llm
  end

  def on(event_name, &block)
    listeners[event_name.to_sym] << block
  end

  def respond(previous_response_id: nil)
    # Track whether response was handled by streamer
    response_handled = false

    # For the first response
    streamer = proc do |chunk|
      case chunk.type
      when "output_text"
        emit(:output_text, chunk.data)
      when "response"
        response = chunk.data
        response_handled = true

        if response.function_requests.any?
          handle_follow_up_response(response)
        else
          emit(:response, { id: response.id })
        end
      end
    end

    response = get_llm_response(streamer: streamer, previous_response_id: previous_response_id)

    # For synchronous (non-streaming) responses, handle function requests if not already handled by streamer
    unless response_handled
      if response && response.function_requests.any?
        handle_follow_up_response(response)
      elsif response
        emit(:response, { id: response.id })
      end
    end
  end

  private
    attr_reader :message, :instructions, :function_tool_caller, :llm

    def handle_follow_up_response(response, depth: 1)
      streamer = proc do |chunk|
        case chunk.type
        when "output_text"
          emit(:output_text, chunk.data)
        when "response"
          # Streamer only emits the final response; recursive function handling
          # is done in the synchronous path below after get_llm_response returns.
          emit(:response, { id: chunk.data.id })
        end
      end

      function_tool_calls = function_tool_caller.fulfill_requests(response.function_requests)

      emit(:response, {
        id: response.id,
        function_tool_calls: function_tool_calls
      })

      # Get follow-up response with tool call results
      follow_up_response = get_llm_response(
        streamer: streamer,
        function_results: function_tool_calls.map(&:to_result),
        previous_response_id: response.id
      )

      # If the follow-up response contains more function requests and we
      # haven't exceeded the recursion limit, continue the tool-call loop.
      # This supports providers like DeepSeek that request tools across
      # multiple turns instead of batching them in a single response.
      if follow_up_response && follow_up_response.function_requests.any? && depth < MAX_FOLLOW_UP_ROUNDS
        handle_follow_up_response(follow_up_response, depth: depth + 1)
      end
    end

    def get_llm_response(streamer:, function_results: [], previous_response_id: nil)
      response = llm.chat_response(
        message.content,
        model: message.ai_model,
        instructions: instructions,
        functions: function_tool_caller.function_definitions,
        function_results: function_results,
        messages: conversation_history,
        streamer: streamer,
        previous_response_id: previous_response_id,
        session_id: chat_session_id,
        user_identifier: chat_user_identifier,
        family: message.chat&.user&.family
      )

      unless response.success?
        raise response.error
      end

      response.data
    end

    def emit(event_name, payload = nil)
      listeners[event_name.to_sym].each { |block| block.call(payload) }
    end

    def listeners
      @listeners ||= Hash.new { |h, k| h[k] = [] }
    end

    def chat_session_id
      chat&.id&.to_s
    end

    def chat_user_identifier
      return unless chat&.user_id

      ::Digest::SHA256.hexdigest(chat.user_id.to_s)
    end

    def chat
      @chat ||= message.chat
    end

    def conversation_history
      messages = []
      return messages unless chat&.messages

      chat.messages
          .where(type: [ "UserMessage", "AssistantMessage" ], status: "complete")
          .includes(:tool_calls)
          .ordered
          .each do |chat_message|
        if chat_message.tool_calls.any?
          messages << {
            role: chat_message.role,
            content: chat_message.content || "",
            tool_calls: chat_message.tool_calls.map(&:to_tool_call)
          }

          chat_message.tool_calls.map(&:to_result).each do |fn_result|
            # Handle nil explicitly to avoid serializing to "null"
            output = fn_result[:output]
            content = if output.nil?
              ""
            elsif output.is_a?(String)
              output
            else
              output.to_json
            end

            messages << {
              role: "tool",
              tool_call_id: fn_result[:call_id],
              name: fn_result[:name],
              content: content
            }
          end

        elsif !chat_message.content.blank?
          messages << { role: chat_message.role, content: chat_message.content || "" }
        end
      end
      messages
    end
end
