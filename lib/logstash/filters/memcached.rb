# encoding: utf-8
require "logstash/filters/base"
require "logstash/namespace"
require 'dalli'
require "lru_redux"

# This filter provides facilities to interact with Memcached.
class LogStash::Filters::Memcached < LogStash::Filters::Base

  # This is how you configure this filter from your Logstash config.
  #
  # Given:
  #  - event with field `hostname` with value `example.com`
  #  - memcached with entry for `threats/hostname/example.com`
  #
  # The following config will inject the value from memcached into
  # the nested field `[threats][host]`:
  #
  # filter {
  #   memcached {
  #     hosts => ["localhost:11211"]
  #     namespace => "threats"
  #     get => {
  #       "hostname:%{[hostname]}" => "[threats][host]"
  #     }
  #   }
  # }
  #
  config_name "memcached"
  
  # an array of memcached hosts to connect to
  # valid forms:
  # ipv4:
  #   - 127.0.0.1
  #   - 127.0.0.1:11211
  # ipv6:
  #   - ::1
  #   - [::1]:11211
  # fqdn:
  #   - your.fqdn.com
  #   - your.fqdn.com:11211
  config :hosts, :validate => :array, :default => ["localhost"]

  # if specified and non-empty, all keys will be prepended with this string and a colon (`:`)
  config :namespace, :validate => :string, :required => false

  # GET data from the given memcached keys to inject into the corresponding event fields.
  #  - memcached keys can reference event fields via sprintf
  #  - event fields can be deep references
  #
  # get {
  #   "memcached-key1" => "[path][to][field1]"
  #   "memcached-key2" => "[path][to][field2]"
  # }
  config :get, :validate => :hash, :required => false

  # SET the given fields from the event to the corresponding keys in memcached
  #  - memcached keys can reference event fields via sprintf
  #  - event fields can be deep references
  #
  # set {
  #   "[path][to][field1]" => "memcached-key1"
  #   "[path][to][field2]" => "memcached-key2"
  # }
  config :set, :validate => :hash, :required => false


  # if performing a setting operation to memcached, the time-to-live in seconds.
  # NOTE: in Memcached, a value of 0 (default) means "never expire"
  config :ttl, :validate => :number, :default => 0

  # Tags the event on failure. This can be used in later analysis.
  config :tag_on_failure, :validate => :string, :default => "_memcached_failure"

  # How long to persist a result in the local in-memory cache, in seconds.
  # A value of 0 will cause the in-memory cache to not be used.
  #
  config :lru_cache_ttl, :validate => :number, :default => 0

  # How large (in number of entries) the size of the in-memory LRU cache
  # should be that sits in front of memcached
  #
  config :lru_cache_max_entries, :validate => :number, :default => 1024

  public

  attr_reader :cache

  def register
    raise(LogStash::ConfigurationError, "'ttl' option cannot be negative") if @ttl < 0

    @memcached_hosts = validate_connection_hosts
    @memcached_options = validate_connection_options
    begin
      @cache = new_connection(@memcached_hosts, @memcached_options)
    rescue => e
      logger.error("failed to connect to memcached", hosts: @memcached_hosts, options: @memcached_options, message: e.message)
      fail("failed to connect to memcached")
    end
    @connected = Concurrent::AtomicBoolean.new(true)
    @connection_mutex = Mutex.new
  end

  def get_lru()
    # We want each LRU cache to be thread-local, because there is no
    # requirement for them to share the same cache, and the performance
    # impact should be positive with less contention for accessing the
    # shared cache.
    #
    # We also need to include the module instance ID, as there could
    # very well be multiple instance of the memcached filter in operation
    # within the same pipeline.
    #
    lru_cache = nil
    if @lru_cache_ttl > 0 && @lru_cache_max_entries > 0
      lru_instance_id = "memcached-#{id}"
      Thread.current[lru_instance_id] ||= LruRedux::Cache.new(@lru_cache_max_entries)
      lru_cache = Thread.current[lru_instance_id]
      lru_cache.ttl = @lru_cache_ttl
    end
    return lru_cache
  end

  def filter(event)
    unless connection_available?
      event.tag(@tag_on_failure)
      return
    end

    begin
      set_success = do_set(event)
      get_success = do_get(event)
      filter_matched(event) if (set_success || get_success)
    rescue Dalli::NetworkError, Dalli::RingError => e
      event.tag(@tag_on_failure)
      logger.error("memcached communication error",  hosts: @memcached_hosts, options: @memcached_options, message: e.message)
      close
    rescue => e
      meta = { :message => e.message }
      meta[:backtrace] = e.backtrace if logger.debug?
      logger.error("unexpected error", meta)
      event.tag(@tag_on_failure)
    end
  end

  def close
    @connection_mutex.synchronize do
      @connected.make_false
      cache.close
    end
  rescue => e
    # we basically ignore any error here as we may be trying to close an invalid
    # connection or if we close on shutdown we can also ignore any error
    logger.debug("error closing memcached connection", :message => e.message)
  end

  private

  def lru_cache_get_multi(memcached_client, memcached_keys)

    lru_cache = get_lru()

    if lru_cache.nil?
      logger.debug("using regular memcached client (no LRU cache)")

      return memcached_client.get_multi(memcached_keys)

    else
      logger.debug("using LRU cache in front of memcached")

      responses = {}
      memcached_keys.each do |key|

        if lru_cache.has_key?(key)
          logger.debug("lru_cache has key; returning from lru cache")
          responses[key] = lru_cache[key]
        else
          logger.debug("lru_cache does not have key; getting from memcached and adding to cache")
          memcache_kv = memcached_client.get_multi([key])
          responses[key] = lru_cache[key] = memcache_kv[key]
          logger.debug("lru_cache utilisation is now #{lru_cache.count}")
          logger.trace("lru_cache content is now #{lru_cache.to_a}")
        end
      end

      return responses
    end
  end

  def do_get(event)
    return false unless @get && !@get.empty?

    event_fields_by_memcached_key = @get.each_with_object({}) do |(memcached_key_template, event_field), memo|
      memcached_key = event.sprintf(memcached_key_template)
      memo[memcached_key] = event_field
    end

    memcached_keys = event_fields_by_memcached_key.keys
    cache_hits_by_memcached_key = lru_cache_get_multi(cache, memcached_keys)

    cache_hits = 0
    event_fields_by_memcached_key.each do |memcached_key, event_field|
      value = cache_hits_by_memcached_key[memcached_key]
      if value.nil?
        logger.trace("cache:get miss", context(key: memcached_key))
      else
        logger.trace("cache:get hit", context(key: memcached_key, value: value))
        cache_hits += 1
        event.set(event_field, value)
      end
    end

    return cache_hits > 0
  end

  def do_set(event)
    return false unless @set && !@set.empty?

    values_by_memcached_key = @set.each_with_object({}) do |(event_field, memcached_key_template), memo|
      memcached_key = event.sprintf(memcached_key_template)
      value = event.get(event_field)

      memo[memcached_key] = value unless value.nil?
    end

    return false if values_by_memcached_key.empty?

    cache.multi do
      values_by_memcached_key.each do |memcached_key, value|
        logger.trace("cache:set", context(key: memcached_key, value: value))
        cache.set(memcached_key, value)
      end
    end

    return true
  end

  def new_connection(hosts, options)
    logger.debug('connecting to memcached', context(hosts: hosts, options: options))
    Dalli::Client.new(hosts, options).tap { |client| client.alive! }
  end

  # reconnect is not thread safe
  def reconnect(hosts, options)
    begin
      @cache = new_connection(hosts, options)
      @connected.make_true
    rescue => e
      logger.error("failed to reconnect to memcached", hosts: hosts, options: options, message: e.message)
      @connected.make_false
    end
    return @connected.value
  end

  def connection_available?
    # this method is called at every #filter method invocation and to minimize synchronization cost
    # only @connected if fist check. The tradeoff is that another worker connection could be in the
    # process of failing and @connected will not yet reflect that but this is acceptable for performance reason.
    return true if @connected.true?

    @connection_mutex.synchronize do
      # the reconnection process is exclusive and will not be be concurrently performed in another worker
      # by re-verifying the state of @connected from the exclusive code.
      return @connected.true? ? true : reconnect(@memcached_hosts, @memcached_options)
    end
  end

  def validate_connection_options
    {}.tap do |options|
      options[:expires_in] = @ttl
      options[:namespace] = @namespace unless @namespace.nil? || @namespace.empty?
    end
  end

  def validate_connection_hosts
    raise(LogStash::ConfigurationError, "'hosts' cannot be empty") if @hosts.empty?
    @hosts.map(&:to_s)
  end

  def context(hash={})
    @plugin_context ||= Hash.new.tap do |hash|
      hash[:namespace] = @namespace unless @namespace.nil? or @namespace.empty?
    end
    return hash if @plugin_context.empty?

    @plugin_context.merge(hash)
  end
end
