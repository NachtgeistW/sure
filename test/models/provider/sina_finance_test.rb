require "test_helper"

class Provider::SinaFinanceTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::SinaFinance.new
    @provider.stubs(:throttle_request)
  end

  # ================================
  #       Symbol normalization
  # ================================

  test "normalize_symbol prefixes bare code using MIC" do
    assert_equal "sh600000", @provider.send(:normalize_symbol, "600000", "XSHG")
    assert_equal "sz000001", @provider.send(:normalize_symbol, "000001", "XSHE")
    assert_equal "bj430047", @provider.send(:normalize_symbol, "430047", "BJSE")
  end

  test "normalize_symbol passes prefixed symbols through" do
    assert_equal "sh600000", @provider.send(:normalize_symbol, "SH600000", nil)
  end

  test "normalize_symbol infers market from leading digit without MIC" do
    assert_equal "sh600000", @provider.send(:normalize_symbol, "600000", nil)
    assert_equal "sh510300", @provider.send(:normalize_symbol, "510300", nil)
    assert_equal "sz000001", @provider.send(:normalize_symbol, "000001", nil)
    assert_equal "sz159915", @provider.send(:normalize_symbol, "159915", nil)
    assert_equal "bj830799", @provider.send(:normalize_symbol, "830799", nil)
  end

  test "normalize_symbol rejects non A-share tickers" do
    assert_raises(Provider::SinaFinance::InvalidSymbolError) do
      @provider.send(:normalize_symbol, "AAPL", "XNAS")
    end
  end

  # ================================
  #       Search
  # ================================

  test "search_securities parses GBK suggest payload" do
    payload = 'var suggestvalue="浦发银行,11,600000,sh600000,浦发银行,,浦发银行,99,1,,;沪深300ETF,22,510300,sh510300,沪深300ETF,,沪深300ETF,99,1,,";'
    mock_client_returning(payload.encode(Encoding::GBK).force_encoding(Encoding::ASCII_8BIT))

    response = @provider.search_securities("600000")

    assert response.success?
    assert_equal 2, response.data.size

    stock = response.data.first
    assert_equal "600000", stock.symbol
    assert_equal "浦发银行", stock.name
    assert_equal "XSHG", stock.exchange_operating_mic
    assert_equal "CN", stock.country_code
    assert_equal "CNY", stock.currency

    etf = response.data.last
    assert_equal "510300", etf.symbol
    assert_equal "XSHG", etf.exchange_operating_mic
  end

  test "search_securities skips unsupported types and markets" do
    payload = 'var suggestvalue="腾讯控股,31,00700,hk00700,腾讯控股,,腾讯控股,99,1,,;浦发银行,11,600000,sh600000,浦发银行,,浦发银行,99,1,,";'
    mock_client_returning(payload.encode(Encoding::GBK).force_encoding(Encoding::ASCII_8BIT))

    response = @provider.search_securities("test")

    assert response.success?
    assert_equal [ "600000" ], response.data.map(&:symbol)
  end

  test "search_securities returns empty array for no matches" do
    mock_client_returning('var suggestvalue="";')

    response = @provider.search_securities("NOPE")

    assert response.success?
    assert_empty response.data
  end

  # ================================
  #       Historical prices
  # ================================

  test "fetch_security_prices maps kline rows to CNY prices within range" do
    rows = [
      { "day" => "2026-06-08", "open" => "10.00", "high" => "10.50", "low" => "9.90", "close" => "10.20", "volume" => "1000" },
      { "day" => "2026-06-09", "open" => "10.20", "high" => "10.60", "low" => "10.10", "close" => "10.40", "volume" => "1200" },
      { "day" => "2026-06-10", "open" => "10.40", "high" => "10.80", "low" => "10.30", "close" => "10.70", "volume" => "900" }
    ]
    mock_client_returning(rows.to_json)

    response = @provider.fetch_security_prices(
      symbol: "600000",
      exchange_operating_mic: "XSHG",
      start_date: Date.parse("2026-06-08"),
      end_date: Date.parse("2026-06-09")
    )

    assert response.success?
    assert_equal 2, response.data.size
    assert_equal Date.parse("2026-06-08"), response.data.first.date
    assert_in_delta 10.20, response.data.first.price
    assert response.data.all? { |p| p.currency == "CNY" && p.exchange_operating_mic == "XSHG" && p.symbol == "600000" }
  end

  test "fetch_security_prices parses relaxed JSON with unquoted keys" do
    body = '[{day:"2026-06-10",open:"10.40",high:"10.80",low:"10.30",close:"10.70",volume:"900"}]'
    mock_client_returning(body)

    response = @provider.fetch_security_prices(
      symbol: "600000",
      exchange_operating_mic: "XSHG",
      start_date: Date.parse("2026-06-10"),
      end_date: Date.parse("2026-06-10")
    )

    assert response.success?
    assert_in_delta 10.70, response.data.first.price
  end

  test "fetch_security_prices fails when no data returned" do
    mock_client_returning("null")

    response = @provider.fetch_security_prices(
      symbol: "600000",
      exchange_operating_mic: "XSHG",
      start_date: Date.current - 5,
      end_date: Date.current
    )

    assert_not response.success?
    assert_instance_of Provider::SinaFinance::InvalidSecurityPriceError, response.error
  end

  # ================================
  #       Single price
  # ================================

  test "fetch_security_price returns closest price on or before date" do
    rows = [
      { "day" => "2026-06-04", "close" => "10.00" },
      { "day" => "2026-06-05", "close" => "10.10" }
    ]
    mock_client_returning(rows.to_json)

    # 2026-06-07 is a Sunday — should fall back to Friday's close
    response = @provider.fetch_security_price(
      symbol: "600000",
      exchange_operating_mic: "XSHG",
      date: Date.parse("2026-06-07")
    )

    assert response.success?
    assert_equal Date.parse("2026-06-05"), response.data.date
    assert_in_delta 10.10, response.data.price
  end

  # ================================
  #       Info
  # ================================

  test "fetch_security_info extracts name from GBK quote payload" do
    payload = 'var hq_str_sh600000="浦发银行,10.00,9.90,10.20,10.50,9.90,10.19,10.20,1000,10000,2026-06-10,15:00:00,00";'
    mock_client_returning(payload.encode(Encoding::GBK).force_encoding(Encoding::ASCII_8BIT))

    response = @provider.fetch_security_info(symbol: "600000", exchange_operating_mic: "XSHG")

    assert response.success?
    assert_equal "浦发银行", response.data.name
    assert_equal "common stock", response.data.kind
    assert_equal "XSHG", response.data.exchange_operating_mic
  end

  test "fetch_security_info classifies Shanghai 51x codes as etf" do
    payload = 'var hq_str_sh510300="沪深300ETF,4.00,3.99,4.02,4.05,3.98,4.01,4.02,1000,4000,2026-06-10,15:00:00,00";'
    mock_client_returning(payload.encode(Encoding::GBK).force_encoding(Encoding::ASCII_8BIT))

    response = @provider.fetch_security_info(symbol: "510300", exchange_operating_mic: "XSHG")

    assert response.success?
    assert_equal "etf", response.data.kind
  end

  # ================================
  #       Helpers
  # ================================

  private

    def mock_client_returning(body)
      mock_response = mock
      mock_response.stubs(:body).returns(body)
      mock_client = mock
      mock_client.stubs(:get).returns(mock_response)
      @provider.stubs(:client).returns(mock_client)
    end
end
