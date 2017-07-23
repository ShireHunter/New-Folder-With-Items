require 'rex/parser/nexpose_raw_nokogiri'
require 'rex/parser/nexpose_xml'

module Msf::DBManager::Import::Nexpose::Raw
  def import_nexpose_raw_noko_stream(args, &block)
    if block
      doc = Rex::Parser::NexposeRawDocument.new(args,framework.db) {|type, data| yield type,data }
    else
      doc = Rex::Parser::NexposeRawDocument.new(args,self)
    end
    parser = ::Nokogiri::XML::SAX::Parser.new(doc)
    parser.parse(args[:data])
  end

  def import_nexpose_rawxml(args={}, &block)
    bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []
    wspace = args[:wspace] || workspace
    if Rex::Parser.nokogiri_loaded
      parser = "Nokogiri v#{::Nokogiri::VERSION}"
      noko_args = args.dup
      noko_args[:blacklist] = bl
      noko_args[:wspace] = wspace
      if block
        yield(:parser, parser)
        import_nexpose_raw_noko_stream(noko_args) {|type, data| yield type,data}
      else
        import_nexpose_raw_noko_stream(noko_args)
      end
      return true
    end
    data = args[:data]

    # Use a stream parser instead of a tree parser so we can deal with
    # huge results files without running out of memory.
    parser = Rex::Parser::NexposeXMLStreamParser.new

    # Since all the Refs have to be in the database before we can use them
    # in a Vuln, we store all the hosts until we finish parsing and only
    # then put everything in the database.  This is memory-intensive for
    # large files, but should be much less so than a tree parser.
    #
    # This method is also considerably faster than parsing through the tree
    # looking for references every time we hit a vuln.
    hosts = []
    vulns = []

    # The callback merely populates our in-memory table of hosts and vulns
    parser.callback = Proc.new { |type, value|
      case type
      when :host
        # XXX: Blacklist should be checked here instead of saving a
        # host we're just going to throw away later
        hosts.push(value)
      when :vuln
        value["id"] = value["id"].downcase if value["id"]
        vulns.push(value)
      end
    }

    REXML::Document.parse_stream(data, parser)

    vuln_refs = nexpose_refs_to_struct(vulns)
    hosts.each do |host|
      if bl.include? host["addr"]
        next
      else
        yield(:address,host["addr"]) if block
      end
      nexpose_host_from_rawxml(host, vuln_refs, wspace)
    end
  end

  #
  # Nexpose Raw XML
  #
  def import_nexpose_rawxml_file(args={})
    filename = args[:filename]
    wspace = args[:wspace] || workspace

    data = ""
    ::File.open(filename, 'rb') do |f|
      data = f.read(f.stat.size)
    end
    import_nexpose_rawxml(args.merge(:data => data))
  end

  # Takes a Host object, an array of vuln structs (generated by nexpose_refs_to_struct()),
  # and a workspace, and reports the vulns on that host.
  def nexpose_host_from_rawxml(h, vstructs, wspace,task=nil)
    hobj = nil
    data = {:workspace => wspace}
    if h["addr"]
      addr = h["addr"]
    else
      # Can't report it if it doesn't have an IP
      return
    end
    data[:host] = addr
    if (h["hardware-address"])
      # Put colons between each octet of the MAC address
      data[:mac] = h["hardware-address"].gsub(':', '').scan(/../).join(':')
    end
    data[:state] = (h["status"] == "alive") ? Msf::HostState::Alive : Msf::HostState::Dead

    # Since we only have one name field per host in the database, just
    # take the first one.
    if (h["names"] and h["names"].first)
      data[:name] = h["names"].first
    end

    if (data[:state] != Msf::HostState::Dead)
      hobj = report_host(data)
      report_import_note(wspace, hobj)
    end

    if h["notes"]
      note = {
          :workspace => wspace,
          :host      => (hobj || addr),
          :type      => "host.vuln.nexpose_keys",
          :data      => {},
          :mode      => :unique_data,
          :task      => task
      }
      h["notes"].each do |v,k|
        note[:data][v] ||= []
        next if note[:data][v].include? k
        note[:data][v] << k
      end
      report_note(note)
    end

    if h["os_family"]
      note = {
          :workspace => wspace,
          :host      => hobj || addr,
          :type      => 'host.os.nexpose_fingerprint',
          :task      => task,
          :data      => {
              :family    => h["os_family"],
              :certainty => h["os_certainty"]
          }
      }
      note[:data][:vendor]  = h["os_vendor"]  if h["os_vendor"]
      note[:data][:product] = h["os_product"] if h["os_product"]
      note[:data][:version] = h["os_version"] if h["os_version"]
      note[:data][:arch]    = h["arch"]       if h["arch"]

      report_note(note)
    end

    h["endpoints"].each { |p|
      extra = ""
      extra << p["product"] + " " if p["product"]
      extra << p["version"] + " " if p["version"]

      # Skip port-0 endpoints
      next if p["port"].to_i == 0

      # XXX This should probably be handled in a more standard way
      # extra << "(" + p["certainty"] + " certainty) " if p["certainty"]

      data             = {}
      data[:workspace] = wspace
      data[:proto]     = p["protocol"].downcase
      data[:port]      = p["port"].to_i
      data[:state]     = p["status"]
      data[:host]      = hobj || addr
      data[:info]      = extra if not extra.empty?
      data[:task]      = task
      if p["name"] != "<unknown>"
        data[:name] = p["name"]
      end
      report_service(data)
    }

    h["vulns"].each_pair { |k,v|

      next if v["status"] !~ /^vulnerable/
      vstruct = vstructs.select {|vs| vs.id.to_s.downcase == v["id"].to_s.downcase}.first
      next unless vstruct
      data             = {}
      data[:workspace] = wspace
      data[:host]      = hobj || addr
      data[:proto]     = v["protocol"].downcase if v["protocol"]
      data[:port]      = v["port"].to_i if v["port"]
      data[:name]      = "NEXPOSE-" + v["id"]
      data[:info]      = vstruct.title
      data[:refs]      = vstruct.refs
      data[:task]      = task
      report_vuln(data)
    }
  end

  #
  # Takes an array of vuln hashes, as returned by the NeXpose rawxml stream
  # parser, like:
  #   [
  #     "id"=>"winreg-notes-protocol-handler", severity="8", "refs"=>["source"=>"BID", "value"=>"10600", ...]
  #     "id"=>"windows-zotob-c", severity="8", "refs"=>["source"=>"BID", "value"=>"14513", ...]
  #   ]
  # and transforms it into a struct, containing :id, :refs, :title, and :severity
  #
  # Other attributes can be added later, as needed.
  def nexpose_refs_to_struct(vulns)
    ret = []
    vulns.each do |vuln|
      next if ret.map {|v| v.id}.include? vuln["id"]
      vstruct = Struct.new(:id, :refs, :title, :severity).new
      vstruct.id = vuln["id"]
      vstruct.title = vuln["title"]
      vstruct.severity = vuln["severity"]
      vstruct.refs = []
      vuln["refs"].each do |ref|
        if ref['source'] == 'BID'
          vstruct.refs.push('BID-' + ref["value"])
        elsif ref['source'] == 'CVE'
          # value is CVE-$ID
          vstruct.refs.push(ref["value"])
        elsif ref['source'] == 'MS'
          vstruct.refs.push('MSB-' + ref["value"])
        elsif ref['source'] == 'URL'
          vstruct.refs.push('URL-' + ref["value"])
        end
      end
      ret.push vstruct
    end
    return ret
  end
end
