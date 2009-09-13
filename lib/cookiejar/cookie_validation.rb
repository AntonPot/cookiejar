
module CookieJar
  # Represents all cookie validation errors
  class InvalidCookieError < StandardError 
    attr_reader :messages
    def initialize message
     if message.is_a? Array
       @messages = message
       message = message.join ', '
     end
     super(message)
    end
  end
  
  # Contains logic to parse and validate cookie headers
  module CookieValidation
    module PATTERN
      include URI::REGEXP::PATTERN

      TOKEN = '[^(),\/<>@;:\\\"\[\]?={}\s]*'
      VALUE1 = "([^;]*)"
      IPADDR = "#{IPV4ADDR}|#{IPV6ADDR}"
      BASE_HOSTNAME = "(?:#{DOMLABEL}\\.)(?:((?:(?:#{DOMLABEL}\\.)+(?:#{TOPLABEL}\\.?))|local))"

      # QUOTED_PAIR = "\\\\[\\x00-\\x7F]"
      # LWS = "\\r\\n(?:[ \\t]+)"
      # TEXT="[\\t\\x20-\\x7E\\x80-\\xFF]|(?:#{LWS})"
      # QDTEXT="[\\t\\x20-\\x21\\x23-\\x7E\\x80-\\xFF]|(?:#{LWS})"
      # QUOTED_TEXT = "\\\"((?:#{QDTEXT}|#{QUOTED_PAIR})*)\\\""
      # VALUE2 = "(#{TOKEN})|#{QUOTED_TEXT}"

    end
    BASE_HOSTNAME = /#{PATTERN::BASE_HOSTNAME}/
    BASE_PATH = /\A((?:[^\/?#]*\/)*)/
    IPADDR = /\A#{PATTERN::IPADDR}\Z/
    HDN = /\A#{PATTERN::HOSTNAME}\Z/
    TOKEN = /\A#{PATTERN::TOKEN}\Z/
    PARAM1 = /\A(#{PATTERN::TOKEN})(?:=#{PATTERN::VALUE1})?\Z/
    # PARAM2 = /\A(#{PATTERN::TOKEN})(?:=#{PATTERN::VALUE2})?\Z/
    
    # TWO_DOT_DOMAINS = /\A\.(com|edu|net|mil|gov|int|org)\Z/
    
    # Converts the input object to a URI (if not already a URI)
    def self.to_uri request_uri
      (request_uri.is_a? URI)? request_uri : (URI.parse request_uri)
    end
    
    # Converts an input cookie or uri to a string representing the path.
    # Assume strings are already paths
    def self.to_path uri_or_path
      if (uri_or_path.is_a? URI) || (uri_or_path.is_a? Cookie)
        uri_or_path.path
      else
        uri_or_path
      end
    end
    
    # Converts an input cookie or uri to a string representing the domain.
    # Assume strings are already domains
    def self.to_domain uri_or_domain
      if uri_or_domain.is_a? URI
        uri_or_domain.host
      elsif uri_or_domain.is_a? Cookie
        uri_or_domain.domain
      else
        uri_or_domain
      end
    end
    
    # Compare a tested domain against the base domain to see if they match, or
    # if the base domain is reachable.
    #
    # returns the effective_host on success, nil on failure
    def self.domains_match tested_domain, base_domain
      base = effective_host base_domain
      search_domains = compute_search_domains_for_host base
      result = search_domains.find do |domain| 
        domain == tested_domain  
      end
    end
    
    # Compute the reach of a hostname (RFC 2965, section 1)
    # Determines the next highest superdomain, or nil if none valid
    def self.hostname_reach hostname
      host = to_domain hostname
      host = host.downcase
      match = BASE_HOSTNAME.match host
      if match
        match[1]
      end
    end
        
    # Compute the base of a path.   
    def self.cookie_base_path path
      BASE_PATH.match(to_path path)[1]
    end
    
    # Processes cookie path data using the following rules:
    # Paths are separated by '/' characters, and accepted values are truncated
    # to the last '/' character. If no path is specified in the cookie, a path
    # value will be taken from the request URI which was used for the site.
    #
    # Note that this will not attempt to detect a mismatch of the request uri domain
    # and explicitly specified cookie path
    def self.determine_cookie_path request_uri, cookie_path
      uri = to_uri request_uri
      cookie_path = to_path cookie_path
      
      if cookie_path == nil || cookie_path.empty?
        cookie_path = cookie_base_path uri.path
      end
      cookie_path
    end
    
    # Given a URI, compute the relevant search domains for pre-existing
    # cookies. This includes all the valid dotted forms for a named or IP
    # domains.
    def self.compute_search_domains request_uri
      uri = to_uri request_uri
      host = uri.host
      compute_search_domains_for_host host
    end
    
    # Given a host, compute the relevant search domains for pre-existing
    # cookies
    def self.compute_search_domains_for_host host
      host = effective_host host
      result = [host]
      unless host =~ IPADDR
        result << ".#{host}"
        base = hostname_reach host
        if base
          result << ".#{base}"
        end
      end
      result
    end
    
    # Processes cookie domain data using the following rules:
    # Domains strings of the form .foo.com match 'foo.com' and all immediate
    # subdomains of 'foo.com'. Domain strings specified of the form 'foo.com' are
    # modified to '.foo.com', and as such will still apply to subdomains.
    #
    # Cookies without an explicit domain will have their domain value taken directly
    # from the URL, and will _NOT_ have any leading dot applied. For example, a request
    # to http://foo.com/ will cause an entry for 'foo.com' to be created - which applies
    # to foo.com but no subdomain.
    #
    # Note that this will not attempt to detect a mismatch of the request uri domain
    # and explicitly specified cookie domain
    def self.determine_cookie_domain request_uri, cookie_domain
      uri = to_uri request_uri
      domain = to_domain cookie_domain
    
      if domain == nil || domain.empty?
        domain = effective_host uri.host
      else
        domain = domain.downcase
        if domain =~ IPADDR || domain.start_with?('.')
          domain
        else
          ".#{domain}" 
        end
      end
    end
    
    # Compute the effective host (RFC 2965, section 1)
    # [host] a string or URI.
    #
    # Has the added additional logic of searching for interior dots specifically, and
    # matches colons to prevent .local being suffixed on IPv6 addresses
    def self.effective_host host_or_uri
      hostname = to_domain host_or_uri
      hostname = hostname.downcase
    
      if /.[\.:]./.match(hostname) || hostname == '.local'
        hostname
      else
        hostname + '.local'
      end
    end
    # Check whether a cookie meets all of the rules to be created, based on 
    # its internal settings and the URI it came from.
    #
    # returns true on success, but will raise an InvalidCookieError on failure
    # with an appropriate error message
    def self.validate_cookie request_uri, cookie
      uri = to_uri request_uri
      request_host = effective_host uri.host
      request_path = uri.path
      request_secure = (uri.scheme == 'https')
      cookie_host = cookie.domain
      cookie_path = cookie.path
      
      errors = []
    
      # From RFC 2965, Section 3.3.2 Rejecting Cookies
    
      # A user agent rejects (SHALL NOT store its information) if the 
      # Version attribute is missing. Note that the legacy Set-Cookie
      # directive will result in an implicit version 0.
      unless cookie.version
        errors << "Version missing"
      end

      # The value for the Path attribute is not a prefix of the request-URI
      unless request_path.start_with? cookie_path 
        errors << "Path is not a prefix of the request uri path"
      end

      unless cookie_host =~ IPADDR || #is an IPv4 or IPv6 address
        cookie_host =~ /.\../ || #contains an embedded dot
        cookie_host == '.local' #is the domain cookie for local addresses
        errors << "Domain format is illegal"
      end
    
      # The effective host name that derives from the request-host does
      # not domain-match the Domain attribute.
      #
      # The request-host is a HDN (not IP address) and has the form HD,
      # where D is the value of the Domain attribute, and H is a string
      # that contains one or more dots.
      unless domains_match cookie_host, uri
        errors << "Domain is inappropriate based on request URI hostname"
      end
    
      # The Port attribute has a "port-list", and the request-port was
      # not in the list.
      unless cookie.ports.nil? || cookie.ports.length != 0
        unless cookie.ports.find_index uri.port
          errors << "Ports list does not contain request URI port"
        end
      end

      raise InvalidCookieError.new errors unless errors.empty?

      # Note: 'secure' is not explicitly defined as an SSL channel, and no
      # test is defined around validity and the 'secure' attribute
      true
    end
    def self.parse_set_cookie set_cookie_value
      args = { }
      params=set_cookie_value.split /;\s*/
      params.each do |param|
        result = PARAM1.match param
        if !result
          raise InvalidCookieError.new "Invalid cookie parameter in cookie '#{set_cookie_value}'"
        end
        key = result[1].downcase.to_sym
        keyvalue = result[2]
        case key
        when :expires
          args[:expires_at] = Time.parse keyvalue
        when :domain
          args[:domain] = keyvalue
        when :path
          args[:path] = keyvalue
        when :secure
          args[:secure] = true
        when :httponly
          args[:http_only] = true
        else
          args[:name] = result[1]
          args[:value] = keyvalue
        end
      end
      args[:version] = 0
      args
    end
  end
end