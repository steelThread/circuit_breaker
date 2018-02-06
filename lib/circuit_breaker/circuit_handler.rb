require 'timeout'

#
#
# CircuitHandler is stateless,
# so the circuit_state gets mixed in with the calling object.
#
#
class CircuitBreaker::CircuitHandler

  #
  # The number of failures needed to trip the breaker.
  #
  attr_reader :failure_threshold

  #
  # The percentage of failures needed to trip the breaker.
  #
  attr_reader :failure_percentage_threshold

  #
  # The minimum number of calls required to trip a percentage checker.
  #
  attr_accessor :failure_percentage_minimum

  #
  # The period of time in seconds before attempting to reset the breaker.
  #
  attr_accessor :failure_timeout

  #
  # The period of time the circuit_method has to return before a timeout exception is thrown.
  #
  attr_accessor :invocation_timeout

  #
  # The exceptions which should be ignored if happens, they are not counted as failures
  #
  attr_accessor :excluded_exceptions

  #
  # Optional logger.
  #
  attr_accessor :logger

  #
  # The object that determines whether or not the circuit has been tripped
  #
  attr_accessor :trip_checker

  DEFAULT_FAILURE_THRESHOLD          = 5
  DEFAULT_FAILURE_TIMEOUT            = 5
  DEFAULT_INVOCATION_TIMEOUT         = 30
  DEFAULT_EXCLUDED_EXCEPTIONS        = []
  DEFAULT_FAILURE_PERCENTAGE_MINIMUM = 3

  def initialize(logger = nil)
    @logger = logger
    @failure_timeout = DEFAULT_FAILURE_TIMEOUT
    @invocation_timeout = DEFAULT_INVOCATION_TIMEOUT
    @excluded_exceptions = DEFAULT_EXCLUDED_EXCEPTIONS

    @failure_threshold = DEFAULT_FAILURE_THRESHOLD
    @failure_percentage_minimum = DEFAULT_FAILURE_PERCENTAGE_MINIMUM
    self.failure_threshold = failure_threshold
  end

  #
  # Returns a new CircuitState instance.
  #
  def new_circuit_state
    ::CircuitBreaker::CircuitState.new
  end

  #
  # Handles the method covered by the circuit breaker.
  #
  def handle(circuit_state, method, *args, &block)
    if is_tripped(circuit_state)
      @logger.debug("handle: breaker is tripped, refusing to execute: #{circuit_state.inspect}") if @logger
      on_circuit_open(circuit_state)
    end

    circuit_state.increment_call_count
    begin
      out = nil
      Timeout.timeout(@invocation_timeout, CircuitBreaker::CircuitBrokenException) do
        out = method[*args, &block]
        on_success(circuit_state)
      end
    rescue Exception => e
      on_failure(circuit_state) unless @excluded_exceptions.include?(e.class)
      raise
    end
    return out
  end

  #
  # Returns true if enough time has elapsed since the last failure time, false otherwise.
  #
  def is_timeout_exceeded(circuit_state)
    now = Time.now

    time_since = now - circuit_state.last_failure_time
    @logger.debug("timeout_exceeded: time since last failure = #{time_since.inspect}") if @logger
    return time_since >= failure_timeout
  end

  #
  # Returns true if the circuit breaker is still open and the timeout has
  # not been exceeded, false otherwise.
  #
  def is_tripped(circuit_state)

    if circuit_state.open? && is_timeout_exceeded(circuit_state)
      @logger.debug("is_tripped: attempting reset into half open state for #{circuit_state.inspect}") if @logger
      circuit_state.attempt_reset
    end

    return circuit_state.open?
  end

  #
  # Called when an individual success happens.
  #
  def on_success(circuit_state)
    @logger.debug("on_success: #{circuit_state.inspect}") if @logger

    if circuit_state.closed?
      @logger.debug("on_success: reset_failure_count #{circuit_state.inspect}") if @logger
      circuit_state.reset_failure_count
    end

    if circuit_state.half_open?
      @logger.debug("on_success: reset circuit #{circuit_state.inspect}") if @logger
      circuit_state.reset
    end
  end

  #
  # Called when an individual failure happens.
  #
  def on_failure(circuit_state)
    @logger.debug("on_failure: circuit_state = #{circuit_state.inspect}") if @logger

    circuit_state.increment_failure_count

    if trip_checker.tripped?(circuit_state) || circuit_state.half_open?
      # Set us into a closed state.
      @logger.debug("on_failure: tripping circuit breaker #{circuit_state.inspect}") if @logger
      circuit_state.trip
    end
  end

  #
  # Called when a call is made and the circuit is open.   Raises a CircuitBrokenException exception.
  #
  def on_circuit_open(circuit_state)
    @logger.debug("on_circuit_open: raising for #{circuit_state.inspect}") if @logger

    raise CircuitBreaker::CircuitBrokenException.new("Circuit broken, please wait for timeout", circuit_state)
  end

  #
  # Sets the trip checker to be a "count" checker with the specified value
  #
  def failure_threshold=(value)
    @trip_checker = ::CircuitBreaker::TripChecker::Count.new(logger, value)
  end

  #
  # Sets the trip checker to be a "percentage" checker with the specified value
  #
  def failure_percentage_threshold=(value)
    @trip_checker = ::CircuitBreaker::TripChecker::Percentage.new(logger, value, failure_percentage_minimum)
  end
end
