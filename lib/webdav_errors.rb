require 'active_support'

module Railsdav
  class BaseError < StandardError
  end

  class LockedError < BaseError
    @@http_status = 423
    cattr_reader :http_status
  end

  class InsufficientStorageError < BaseError
    @@http_status = 507
    cattr_reader :http_status
  end

  class ConflictError < BaseError
    @@http_status = 405      
    cattr_reader :http_status
  end

  class ForbiddenError < BaseError
    @@http_status = 403
    cattr_reader :http_status
  end

  class BadGatewayError < BaseError
    @@http_status = 502
    cattr_reader :http_status
  end

  class PreconditionFailsError < BaseError
    @@http_status = 412
    cattr_reader :http_status
  end

  class NotFoundError < BaseError
    @@http_status = 404
    cattr_reader :http_status
  end

  class UnSupportedTypeError < BaseError
    @@http_status = 415
    cattr_reader :http_status
  end

  class UnknownWebDavMethodError < BaseError
    @@http_status = 405
    cattr_reader :http_status
  end

  class BadRequestBodyError < BaseError
    @@http_status = 400
    cattr_reader :http_status
  end

  class TODO409Error < BaseError
    @@http_status = 409
    cattr_reader :http_status
  end
end
