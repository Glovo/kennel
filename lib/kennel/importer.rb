# frozen_string_literal: true

module Kennel
  class Importer
    TITLES = [:name, :title, :board_title].freeze
    SORT_ORDER = [*TITLES, :id, :kennel_id, :type, :tags, :query, :message, :description, :template_variables].freeze

    def initialize(api)
      @api = api
    end

    def import_all()
      if (ENV["RESOURCE"])
        api_resources = ENV["RESOURCE"].split(/\s*,\s*/)
      else
        api_resources = Models::Base.subclasses.map do |m|
          next unless m.respond_to?(:api_resource)
          m.api_resource
        end
      end

      Utils.parallel(api_resources.compact.uniq) do |api_resource|
        model = Kennel::Models.const_get(api_resource.capitalize)
        # lookup monitors without adding unnecessary downtime information
        tags = ENV["TAGS"] || ""
        # TODO dashboards need to be imported by id
        results = @api.list(api_resource, with_downtimes: false, name: ENV["NAME"], monitor_tags: tags.split(/\s*,\s*/))
        if results.is_a?(Hash)
          results = results[results.keys.first]
          results.each { |r| r[:id] = Integer(r.fetch(:id)) }
        end
        results.map do |resource|
          #resource[:api_resource] = api_resource
          model_to_string(api_resource, model, resource).strip()
        end
      end.flatten(1).join(",\n")
    end

    def import(resource, id)
      begin
        model =
          begin
            Kennel::Models.const_get(resource.capitalize)
          rescue NameError
            raise ArgumentError, "#{resource} is not supported"
          end
        data = @api.show(model.api_resource, id)
      rescue StandardError => e
        retried ||= 0
        retried += 1
        raise e if retried != 1 || resource != "dash" || !e.message.match?(/No \S+ matches that/)
        resource = "screen"
        retry
      end
      model_to_string(resource, model, data)
    end

    private

    def model_to_string(resource, model, data)
      data = data[resource.to_sym] || data
      id = data.fetch(:id) # store numerical id returned from the api
      model.normalize({}, data)
      data[:id] = id
      data[:kennel_id] = Kennel::Utils.parameterize(data.fetch(TITLES.detect { |t| data[t] }))

      if resource == "monitor"
        # flatten monitor options so they are all on the base
        data.merge!(data.delete(:options))
        data.merge!(data.delete(:thresholds) || {})
        [:notify_no_data, :notify_audit].each { |k| data.delete(k) if data[k] } # monitor uses true by default
        data = data.slice(*model.instance_methods)

        # make query use critical method if it matches
        critical = data[:critical]
        query = data[:query]
        if query && critical
          query.sub!(/([><=]) (#{Regexp.escape(critical.to_f.to_s)}|#{Regexp.escape(critical.to_i.to_s)})$/, "\\1 \#{critical}")
        end
      end

      pretty = pretty_print(data).lstrip.gsub("\\#", "#")
      <<~RUBY
        #{model.name}.new(
          self,
          #{pretty}
        )
      RUBY
    end

    def pretty_print(hash)
      list = hash.sort_by { |k, _| [SORT_ORDER.index(k) || 999, k] } # important to the front and rest deterministic
      list.map do |k, v|
        pretty_value =
          if v.is_a?(Hash) || (v.is_a?(Array) && !v.all? { |e| e.is_a?(String) })
            # update answer here when changing https://stackoverflow.com/questions/8842546/best-way-to-pretty-print-a-hash
            # (exclude last indent gsub)
            pretty = JSON.pretty_generate(v)
              .gsub(": null", ": nil")
              .gsub(/(^\s*)"([a-zA-Z][a-zA-Z\d_]*)":/, "\\1\\2:") # "foo": 1 -> foo: 1
              .gsub(/^/, "    ") # indent

            "\n#{pretty}\n  "
          elsif k == :message
            "\n    <<~TEXT\n#{v.each_line.map { |l| l.strip.empty? ? "\n" : "      #{l}" }.join}\n    TEXT\n  "
=begin
          elsif v.is_a?(Numeric)
            " #{v.to_i == v ? v.to_i : v} "
=end
          else
            " #{v.inspect} "
          end
        "  #{k}: -> {#{pretty_value}}"
      end.join(",\n")
    end
  end
end
