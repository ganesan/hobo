require 'rexml/document'

module Hobo::Dryml

  class Template
    DRYML_NAME = "[a-zA-Z_][a-zA-Z0-9_]*"

    APPLICATION_TAGLIB = "hobolib/application"
    CORE_TAGLIB = "plugins/hobo/tags/core"

    def initialize(src, environment, template_path)
      @src = src
      @environment = environment # a class or a module

      @template_path = if template_path.starts_with?(RAILS_ROOT)
                         template_path[RAILS_ROOT.length+1..-1]
                       else
                         template_path
                       end
      @last_element = nil
      @tags = {}
    end

    def compile(local_names=[], auto_taglibs=true)
      if auto_taglibs
        auto_imports = if Hobo.current_theme
                         [APPLICATION_TAGLIB,
                          "hobolib/themes/#{Hobo.current_theme}/application",
                          CORE_TAGLIB]
                       else
                         [APPLICATION_TAGLIB,
                          CORE_TAGLIB]
                       end

        if template_path.starts_with?("app") or template_path == Hobo::Dryml::EMPTY_PAGE
          # import whatever's next in the chain
          found = nil
          auto_imports.each_with_index {|x, i| found = i if template_path == expand_template_path(x)}
          import_taglib(found ? auto_imports[found+1] : APPLICATION_TAGLIB)
        else
          # Everything outside app just implicitly gets core and that's it
          import_taglib(CORE_TAGLIB)
        end
      end

      if is_taglib?
        process_src
      else
        create_render_page_method(local_names)
      end

      @environment.tag_defs = @tags
    end

    attr_reader :tags, :template_path

    def create_render_page_method(local_names)
      erb_src = process_src
      src = ERB.new(erb_src).src[("_erbout = '';").length..-1]

      locals = local_names.map{|l| "#{l} = __local_assigns__[:#{l}];"}.join(' ')

      method_src = ("def render_page(__page_this__, __local_assigns__); " +
                    "#{locals} new_object_context(__page_this__) do " +
                    src +
                    "; end + part_contexts_js; end")

      @environment.class_eval(method_src, template_path, 1)
      @environment.compiled_local_names = local_names
    end

    def is_taglib?
      @environment.class == Module
    end

    def process_src
      # Replace <%...%> scriptlets with xml-safe references into a hash of scriptlets
      @scriptlets = {}
      src = @src.gsub(/<%(.*?)%>/m) do
        _, scriptlet = *Regexp.last_match
        id = @scriptlets.size + 1
        @scriptlets[id] = scriptlet
        newlines = "\n" * scriptlet.count("\n")
        "[![HOBO-ERB#{id}#{newlines}]!]"
      end

      @xmlsrc = "<dryml_page>" + src + "</dryml_page>"

      @doc = REXML::Document.new(RexSource.new(@xmlsrc))

      erb_src = restore_erb_scriptlets(children_to_erb(@doc.root))

      erb_src
    end


    def restore_erb_scriptlets(src)
      src.gsub(/\[!\[HOBO-ERB(\d+)\s*\]!\]/m) { "<%#{@scriptlets[Regexp.last_match[1].to_i]}%>" }
    end


    def erb_process(src)
      ERB.new(restore_erb_scriptlets(src)).src
    end


    def children_to_erb(nodes)
      nodes.map{|x| node_to_erb(x)}.join
    end


    def node_to_erb(node)
      case node

      # v important this comes before REXML::Text, as REXML::CData < REXML::Text
      when REXML::CData
        REXML::CData::START + node.to_s + REXML::CData::STOP

      when REXML::Text
        node.to_s

      when REXML::Element
        element_to_erb(node)
      end
    end


    def element_to_erb(el)
      dryml_exception("badly placed parameter tag <#{el.name}>", el) if
        el.name.starts_with?(":")

      @last_element = el
      case el.name

      when "taglib"
        taglib_element(el)
        # return nothing - the import has no presence in the erb source
        ""

      when "def"
        def_element(el)

      when "tagbody"
        tagbody_element(el)

      else
        tag = @tags[el.name]
        if tag
          tag_call(tag, el)
        elsif el.name.not_in?(Hobo.static_tags)
          tag_call(tag, el)
        else
          html_element_to_erb(el)
        end
      end
    end


    def taglib_element(el)
      require_toplevel(el)
      require_attribute(el, "as", /^#{DRYML_NAME}$/, true)
      if el.attributes["src"]
        import_taglib(el.attributes["src"], el.attributes["as"])
      elsif el.attributes["module"]
        import_module(el.attributes["module"].constantize, el.attributes["as"])
      end
    end


    def expand_template_path(path)
      (if path.starts_with? "plugins"
         "vendor/" + path
       elsif path.include?("/")
         "app/views/#{path}"
       else
         template_dir = File.dirname(template_path)
         "#{template_dir}/#{path}"
       end
       ) + ".dryml"
    end


    def import_taglib(src_path, as=nil)
      path = expand_template_path(src_path)
      logger.info("import dryml: " + path)
      unless template_path == path
        taglib = Taglib.get(RAILS_ROOT + "/" + path)
        tags = taglib.import_into(@environment, as)
        # add imported tags, but don't overwrite tags defined locally
        tags.each_pair {|k,v| @tags[k] = v unless @tags.has_key?(k) }
      end
    end


    def import_module(mod, as=nil)
      raise "not implemented!" if as
      logger.info "import module: " + mod.inspect
      @environment.send(:include, mod)
      @tags.update mod.hobo_tags if defined? mod.hobo_tags
    end


    def define_tags(root)
      root.elements.oselect{name == "def"}.each do |el|
      end
    end


    def def_element(el)
      require_toplevel(el)
      require_attribute(el, "tag", /^#{DRYML_NAME}$/)
      require_attribute(el, "attrs", /^\s*#{DRYML_NAME}(\s*,\s*#{DRYML_NAME})*\s*$/, true)
      require_attribute(el, "alias_of", /^#{DRYML_NAME}$/, true)
      require_attribute(el, "alias_current", /^#{DRYML_NAME}$/, true)

      name = el.attributes["tag"]

      alias_of = el.attributes['alias_of']
      alias_current = el.attributes['alias_current']

      dryml_exception("def cannot have both alias_of and alias_current", el) if alias_of && alias_current
      dryml_exception("def with alias_of must be empty", el) if alias_of and el.size > 0

      if alias_of || alias_current
        old_name = alias_current ? name : alias_of
        new_name = alias_current ? alias_current : name
        old = @tags[old_name]
        dryml_exception("no tag '#{old_name}' to alias", el) unless old

        @environment.send(:alias_method, new_name.to_sym, old_name.to_sym)
      end
        
      if alias_of
        @tags[name] = Hobo::Dryml::TagDef.new(name.to_sym, old.attrs)
        "<% #{tag_newlines(el)} %>"
      else
        attrspec = el.attributes["attrs"]
        attr_names = attrspec ? attrspec.split(/\s*,\s*/) : []

        invalids = attr_names & %w{obj attr this}
        dryml_exception("invalid attrs in def: #{invalids * ', '}", el) unless invalids.empty?

        tag = @tags[name] = Hobo::Dryml::TagDef.new(name.to_sym, attr_names.omap{to_sym})

        create_tag_method(el, tag)
      end
    end


    def create_tag_method(el, tag)
      name = Hobo::Dryml.unreserve(tag.name)

      # A statement to assign values to local variables named after the tag's attrs.
      # Careful to unpack the list returned by _tag_locals even if there's only
      # a single var (options) on the lhs (hence the trailing ',' on options)
      setup_locals = ( (tag.attrs.map{|a| "#{Hobo::Dryml.unreserve(a)}, "} + ['options,']).join +
                       " = _tag_locals(__options__, #{tag.attrs.inspect})" )

      start = "_tag_context(__options__, __block__) do |tagbody| #{setup_locals}"

      method_src = ( "<% def #{name}(__options__={}, &__block__); #{start} " +
                     # reproduce any line breaks in the start-tag so that line numbers are preserved
                     tag_newlines(el) + "%>" +
                     children_to_erb(el) +
                     "<% @output; end; end %>" )
      
      src = erb_process(method_src)
      @environment.class_eval(src, template_path, element_line_num(el))

      # keep line numbers matching up
      "<% #{"\n" * method_src.count("\n")} %>"
    end


    def tagbody_element(el)
      dryml_exception("tagbody can only appear inside a <def>", el) unless
        find_ancestor(el) {|e| e.name == 'def'}
      dryml_exception("tagbody cannot appear inside a part", el) if
        find_ancestor(el) {|e| e.attributes['part_id']}
      tagbody_call(el)
    end


    def tagbody_call(el)
      options = if obj = el.attributes['obj']
                  "{ :obj => #{attribute_to_ruby(obj)} }"
                elsif attr = el.attributes['attr']
                  "{ :attr => #{attribute_to_ruby(attr)} }"
                else
                  ""
                end
      else_ = attribute_to_ruby(options['else'])
      "<%= tagbody ? tagbody.call(#{options}) : #{else_} %>"
    end


    def part_element(el, content)
      require_attribute(el, "part_id", /^#{DRYML_NAME}$/)
      part_name  = el.attributes['part_id']
      dom_id = el.attributes['id'] || part_name

      part_src = "<% def #{part_name}_part #{tag_newlines(el)}; new_context do %>" +
        content +
        "<% end; end %>"
      create_part(part_src, element_line_num(el))

      newlines = "\n" * part_src.count("\n")
      res = "<%= call_part(#{attribute_to_ruby(dom_id)}, :#{part_name}) #{newlines} %>"
      res
    end


    def create_part(erb_src, line_num)
      src = erb_process(erb_src)
      # Add a method to the part module for this template
      @environment.class_eval(src, template_path, line_num)
    end

    def tag_call(tag, el)
      require_attribute(el, "inner", /#{DRYML_NAME}/, true)
      
      # find out if it's empty before removing any <:param_tags>
      empty_el = el.size == 0

      # gather <:param_tags>, and remove them from the dom
      param_elems = {}
      at_start = true
      el.elements.each do |e|
        if e.name.starts_with?(":")
          e.remove
          
          param_value = if e.size == 0
                          # childless param tag, e.g. <:foo x="y"/>, becomes a hash { :x => 'y' }
                          hash = Hash.build(e.attributes.keys) {|n| [n, attribute_to_ruby(e.attributes[n])]}
                          hash_to_ruby(hash)
                        else
                          "(capture do %>#{children_to_erb(e)}<%; end)"
                        end
          
          param_elems[e.name[1..-1]] = param_value
        end
      end

      name = Hobo::Dryml.unreserve(el.name)
      options = tag_options(el, param_elems)
      newlines = tag_newlines(el)
      inner = el.attributes["inner"]
      call = if inner.blank? 
               "#{name}(#{options})"
             else
               "call_inner_tag(:#{name}, #{options}, options[:#{inner}])"
             end

      part_id = el.attributes['part_id']
      if empty_el
        if part_id
          "<span id='#{part_id}'>" + part_element(el, "<%= #{call} %>") + "</span>"
        else
          "<%= #{call} #{newlines}%>"
        end
      else
        children = children_to_erb(el)
        if part_id
          id = el.attributes['id'] || part_id
          "<span id='<%= #{attribute_to_ruby(id)} %>'>" +
            part_element(el, "<% _erbout.concat(#{call} do %>#{children}<% end) %>") +
            "</span>"
        else
          "<% _erbout.concat(#{call} do #{newlines}%>#{children}<% end) %>"
        end
      end
    end


    def tag_options(el, param_elems)
      attributes = el.attributes

      # ensure no param given as both attribute and <:tag>
      dryml_exception("duplicate attribute/parameter-tag #{param}", el) unless
        (param_elems.keys & attributes.keys).empty?
      
      options = hash_to_ruby(all_options(attributes, param_elems))

      xattrs = el.attributes['xattrs']
      if xattrs
        extra_options = if xattrs.blank?
                          "options"
                        elsif xattrs.starts_with?("#")
                          xattrs[1..-1]
                        else
                          dryml_exception("invalid xattrs", el)
                        end
        "#{options}.update(#{extra_options})"
      else
        options
      end
    end


    def all_options(attributes, param_elems)
      opts = {}
      (attributes.keys + param_elems.keys).each do |name|
        value = if param_elems.include?(name)
                  param_elems[name]
                else
                  attribute_to_ruby(attributes[name])
                end
        begin
          add_option(opts, name.split('.'), value)
        rescue DrymlExcpetion
          dryml_exception("inner-attribute conflict for {name}")
        end
      end
      opts
    end
    
    def hash_to_ruby(hash)
      pairs = hash.map do |k, v|
        val = v.is_a?(Hash) ? hash_to_ruby(v) : v
        ":#{k} => #{val}"
      end
      "{ #{pairs * ', '} }"
    end
    
    def add_option(options, names, value)
      if names.length == 1
        options[names.first] = value
      elsif names.length > 1
        v = options[names.first]
        if v.is_a? Hash
          # it's ready for the inner-attribute - do nothing
        elsif v.nil?
          options[names.first] = v = {}
        else
          # Conflict, i.e. a = "ping" and a.b = "pong"
          # Rescued by caller (all_options)
          raise DrymlExcpetion.new
        end
        add_option(v, names[1..-1], value)
      end
    end

    
    def html_element_to_erb(el)
      start_tag_src = el.instance_variable_get("@start_tag_source").
        gsub(REXML::CData::START, "").gsub(REXML::CData::STOP, "")

      xattrs = el.attributes["xattrs"]
      if xattrs
        attr_args = if xattrs.starts_with?('#')
                      xattrs[1..-1]
                    elsif xattrs.blank?
                      "options"
                    else
                      dryml_exception("invalid xattrs", el)
                    end
        class_attr = el.attributes["class"]
        if class_attr
          raise HoboError.new("invalid class attribute with xattrs: '#{class_attr}'") if
            class_attr =~ /'|\[!\[HOBO-ERB/

          attr_args.concat(", '#{class_attr}'")
          start_tag_src.sub!(/\s*class\s*=\s*('[^']*?'|"[^"]*?")/, "")
        end
        start_tag_src.sub!(/\s*xattrs\s*=\s*('[^']*?'|"[^"]*?")/, " <%= xattrs(#{attr_args}) %>")
      end

      if start_tag_src.ends_with?("/>")
        start_tag_src
      else
        if el.attributes['part_id']
          body = part_element(el, children_to_erb(el))
          if el.attributes["id"]
            # remove part_id, and eval the id attribute with an erb scriptlet
            start_tag_src.sub!(/\s*part_id\s*=\s*('[^']*?'|"[^"]*?")/, "")
            id_expr = attribute_to_ruby(el.attributes['id'])
            start_tag_src.sub!(/id\s*=\s*('[^']*?'|"[^"]*?")/, "id='<%= #{id_expr} %>'")
          else
            # rename part_id to id
            start_tag_src.sub!(/part_id\s*=\s*('[^']*?'|"[^"]*?")/, "id=\\1")
          end
          dryml_exception("multiple part ids", el) if start_tag_src.index("part_id=")


          start_tag_src + body + "</#{el.name}>"
        else
          start_tag_src + children_to_erb(el) + "</#{el.name}>"
        end
      end
    end

    def attribute_to_ruby(attr)
      dryml_exception("erb scriptlet in attribute of defined tag") if attr && attr.index("[![HOBO-ERB")
      if attr.nil?
        "nil"
      elsif is_code_attribute?(attr)
        "(#{attr[1..-1]})"
      else
        if not attr =~ /"/
          '"' + attr + '"'
        elsif not attr =~ /'/
          "'#{attr}'"
        else
          dryml_exception("invalid quote(s) in attribute value")
        end
      end
    end

    def find_ancestor(el)
      e = el.parent
      until e.is_a? REXML::Document
        return e if yield(e)
        e = e.parent
      end
      return nil
    end

    def require_toplevel(el)
      dryml_exception("<#{el.name}> can only be at the top level", el) if el.parent != @doc.root
    end

    def require_attribute(el, name, rx=nil, optional=false)
      val = el.attributes[name]
      if val
        dryml_exception("invalid #{name}=\"#{val}\" attribute on <#{el.name}>", el) unless val =~ rx
      else
        dryml_exception("missing #{name} attribute on <#{el.name}>", el) unless optional
      end
    end

    def dryml_exception(message, el=nil)
      el ||= @last_element
      raise DrymlException.new(message + " -- at #{template_path}:#{element_line_num(el)}")
    end

    def element_line_num(el)
      offset = el.instance_variable_get("@source_offset")
      line_no = @xmlsrc[0..offset].count("\n") + 1
    end

    def tag_newlines(el)
      src = el.instance_variable_get("@start_tag_source")
      "\n" * src.count("\n")
    end

    def is_code_attribute?(attr_value)
      attr_value.starts_with?("#")
    end

    def logger
      ActionController::Base.logger rescue nil
    end

  end

end
