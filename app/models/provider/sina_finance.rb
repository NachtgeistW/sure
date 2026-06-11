class Provider::SinaFinance < Provider
  include SecurityConcept, RateLimitable
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::SinaFinance::Error
  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)
  InvalidSymbolError = Class.new(Error)

  # Cache duration for repeated requests (5 minutes)
  CACHE_DURATION = 5.minutes

  # Minimum delay between requests to avoid being blocked
  MIN_REQUEST_INTERVAL = 0.5

  # Sina's daily kline endpoint returns at most ~1023 bars per request.
  # Calendar days >= trading days, so capping the calendar lookback at this
  # number guarantees the request never exceeds the bar limit.
  KLINE_MAX_DATALEN = 1023

  # Sina endpoints reject requests without a finance.sina.com.cn Referer
  REFERER = "https://finance.sina.com.cn".freeze

  # Sina market prefixes ↔ ISO 10383 operating MICs
  MARKET_PREFIX_TO_MIC = {
    "sh" => "XSHG", # Shanghai Stock Exchange
    "sz" => "XSHE", # Shenzhen Stock Exchange
    "bj" => "BJSE"  # Beijing Stock Exchange
  }.freeze
  MIC_TO_MARKET_PREFIX = MARKET_PREFIX_TO_MIC.invert.freeze

  # Sina suggest type codes worth surfacing:
  # 11 = A-share stock, 12 = B-share stock, 22 = ETF, 23 = LOF
  SUGGEST_TYPES = "11,12,22,23".freeze
  SUGGEST_TYPE_KINDS = {
    "11" => "common stock",
    "12" => "common stock",
    "22" => "etf",
    "23" => "mutual fund"
  }.freeze

  # Exchange-traded fund types — listed on an exchange even when Sina's
  # suggest endpoint returns them with the open-fund "of" symbol prefix
  ETF_TYPES = %w[22 23].freeze

  def initialize
    # Sina Finance public endpoints require no API key
    @cache_prefix = "sina_finance"
  end

  def max_history_days
    KLINE_MAX_DATALEN
  end

  def healthy?
    # SSE Composite Index is always quotable when the API is up
    fetch_kline_rows("sh000001", 1).present?
  rescue => e
    false
  end

  def usage
    with_provider_response do
      UsageData.new(
        used: nil,
        limit: nil,
        utilization: nil,
        plan: "Free (no key required)"
      )
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      query = symbol.to_s.strip
      raise Error, "Search query cannot be blank" if query.blank?

      cache_key = "search_#{query}_#{country_code}_#{exchange_operating_mic}"
      if cached_result = get_cached_result(cache_key)
        cached_result
      else
        throttle_request
        response = client.get("#{suggest_base_url}/suggest/type=#{SUGGEST_TYPES}&key=#{encode_query(query)}")
        body = decode_gbk(response.body)

        # Response format: var suggestvalue="name,type,code,prefixed_symbol,name,...;...";
        payload = body[/"(.*)"/m, 1].to_s

        securities = payload.split(";").filter_map do |entry|
          fields = entry.split(",")
          next if fields.length < 5

          type = fields[1]
          code = fields[2].to_s.upcase
          prefixed_symbol = fields[3].to_s.downcase
          name = fields[4].presence || code

          next unless SUGGEST_TYPE_KINDS.key?(type)

          mic = MARKET_PREFIX_TO_MIC[prefixed_symbol[0, 2]]

          # ETFs/LOFs often come back with the open-fund "of" prefix
          # (e.g. of159509) even though they trade on an exchange — infer
          # the market from the fund code instead.
          if mic.nil? && ETF_TYPES.include?(type) && code.match?(/\A\d{6}\z/)
            mic = MARKET_PREFIX_TO_MIC[infer_market_prefix(code.downcase)]
          end

          next unless mic.present?
          next if exchange_operating_mic.present? && mic != exchange_operating_mic

          Security.new(
            symbol: code,
            name: name,
            logo_url: nil,
            exchange_operating_mic: mic,
            country_code: "CN",
            currency: "CNY"
          )
        end.uniq { |s| [ s.symbol, s.exchange_operating_mic ] }.first(25)

        cache_result(cache_key, securities)
        securities
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      sina_symbol = normalize_symbol(symbol, exchange_operating_mic)

      throttle_request
      response = client.get("#{quote_base_url}/list=#{sina_symbol}")
      body = decode_gbk(response.body)

      # Response format: var hq_str_sh600000="浦发银行,open,prev_close,price,...";
      payload = body[/"([^"]*)"/, 1].to_s
      name = payload.split(",").first

      raise Error, "No security info found for #{symbol}" if name.blank?

      SecurityInfo.new(
        symbol: symbol,
        name: name,
        links: nil,
        logo_url: nil,
        description: nil,
        kind: infer_kind(sina_symbol),
        exchange_operating_mic: exchange_operating_mic
      )
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      cache_key = "security_price_#{symbol}_#{exchange_operating_mic}_#{date}"
      if cached_result = get_cached_result(cache_key)
        cached_result
      else
        # Fetch a small range and find the closest match (markets close on weekends/holidays)
        prices_response = fetch_security_prices(
          symbol: symbol,
          exchange_operating_mic: exchange_operating_mic,
          start_date: date - 10.days,
          end_date: date
        )

        raise prices_response.error if prices_response.error.present?

        prices = prices_response.data
        target_price = prices.find { |p| p.date == date } ||
                       prices.select { |p| p.date <= date }.max_by(&:date)

        raise InvalidSecurityPriceError, "No price found for #{symbol} on or before #{date}" unless target_price

        cache_result(cache_key, target_price)
        target_price
      end
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      sina_symbol = normalize_symbol(symbol, exchange_operating_mic)
      start_date = start_date.to_date
      end_date = end_date.to_date
      raise Error, "Start date cannot be after end date" if start_date > end_date

      # The kline endpoint always returns the most recent N daily bars, so
      # size the request to reach back from today to start_date.
      datalen = ((Date.current - start_date).to_i + 1).clamp(1, KLINE_MAX_DATALEN)

      throttle_request
      rows = fetch_kline_rows(sina_symbol, datalen)

      raise InvalidSecurityPriceError, "No price data found for #{symbol}" if rows.blank?

      mic = exchange_operating_mic.presence || MARKET_PREFIX_TO_MIC[sina_symbol[0, 2]]

      prices = rows.filter_map do |row|
        close = row["close"].to_f
        next if close <= 0

        date = Date.parse(row["day"].to_s) rescue nil
        next if date.nil? || date < start_date || date > end_date

        Price.new(
          symbol: symbol,
          date: date,
          price: close,
          currency: "CNY",
          exchange_operating_mic: mic
        )
      end

      prices.sort_by(&:date)
    end
  end

  private

    def quote_base_url
      ENV["SINA_FINANCE_QUOTE_URL"] || "https://hq.sinajs.cn"
    end

    def suggest_base_url
      ENV["SINA_FINANCE_SUGGEST_URL"] || "https://suggest3.sinajs.cn"
    end

    def kline_base_url
      ENV["SINA_FINANCE_KLINE_URL"] || "https://quotes.sina.cn"
    end

    # ================================
    #         Symbol Handling
    # ================================

    # Converts a stored ticker ("600000" + XSHG) into Sina's prefixed form
    # ("sh600000"). Already-prefixed symbols pass through.
    def normalize_symbol(symbol, exchange_operating_mic)
      s = symbol.to_s.strip.downcase
      return s if s.match?(/\A(sh|sz|bj)\d{6}\z/)

      raise InvalidSymbolError, "Invalid Sina Finance symbol: #{symbol}" unless s.match?(/\A\d{6}\z/)

      prefix = MIC_TO_MARKET_PREFIX[exchange_operating_mic] || infer_market_prefix(s)
      raise InvalidSymbolError, "Cannot determine market for symbol: #{symbol}" unless prefix

      "#{prefix}#{s}"
    end

    # Infers the market from the code's leading digit when no MIC is given.
    # 6/5/9 → Shanghai, 0/1/2/3 → Shenzhen, 4/8 → Beijing
    def infer_market_prefix(code)
      case code[0]
      when "6", "5", "9" then "sh"
      when "0", "1", "2", "3" then "sz"
      when "4", "8" then "bj"
      end
    end

    # Classifies funds by their code range (Shanghai 50/51/56/58, Shenzhen 15/16)
    def infer_kind(sina_symbol)
      prefix = sina_symbol[0, 2]
      code = sina_symbol[2..]

      fund = (prefix == "sh" && code.match?(/\A(50|51|56|58)/)) ||
             (prefix == "sz" && code.match?(/\A(15|16)/))

      fund ? "etf" : "common stock"
    end

    # ================================
    #          API Requests
    # ================================

    # Fetches up to `datalen` most recent daily bars for a prefixed symbol.
    # Returns an array of hashes: { "day" => "2026-01-02", "close" => "10.50", ... }
    def fetch_kline_rows(sina_symbol, datalen)
      response = client.get("#{kline_base_url}/cn/api/json_v2.php/CN_MarketDataService.getKLineData") do |req|
        req.params["symbol"] = sina_symbol
        req.params["scale"] = 240 # daily bars
        req.params["ma"] = "no"
        req.params["datalen"] = datalen
      end

      parse_kline_body(response.body.to_s)
    end

    def parse_kline_body(body)
      data = begin
        JSON.parse(body)
      rescue JSON::ParserError
        # Sina occasionally returns relaxed JSON with unquoted keys
        JSON.parse(body.gsub(/([{,])\s*([a-zA-Z_]\w*)\s*:/, '\1"\2":'))
      end

      data.is_a?(Array) ? data : nil
    rescue JSON::ParserError => e
      raise Error, "Invalid kline response format: #{e.message}"
    end

    # Sina text endpoints (quotes, suggest) respond in GBK
    def decode_gbk(body)
      body.to_s.dup.force_encoding(Encoding::GBK).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    # The suggest endpoint expects GBK percent-encoding for Chinese queries
    def encode_query(query)
      CGI.escape(query.encode(Encoding::GBK))
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      CGI.escape(query)
    end

    def client
      @client ||= Faraday.new(ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.request(:retry, {
          max: 3,
          interval: 1.0,
          interval_randomness: 0.5,
          backoff_factor: 2,
          retry_statuses: [ 429 ],
          exceptions: [ Faraday::ConnectionFailed, Faraday::TimeoutError ]
        })

        faraday.response :raise_error

        # Sina blocks requests without a finance.sina.com.cn Referer
        faraday.headers["Referer"] = REFERER
        faraday.headers["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"
        faraday.headers["Accept"] = "*/*"

        faraday.options.timeout = 10
        faraday.options.open_timeout = 5
      end
    end

    # ================================
    #           Caching
    # ================================

    # Preserve provider-scoped error subclasses (RateLimitable's default wraps
    # everything non-Faraday into the generic Error)
    def default_error_transformer(error)
      return error if error.is_a?(Error)
      super
    end

    def get_cached_result(key)
      Rails.cache.read("#{@cache_prefix}_#{key}")
    end

    def cache_result(key, data)
      Rails.cache.write("#{@cache_prefix}_#{key}", data, expires_in: CACHE_DURATION)
    end
end
