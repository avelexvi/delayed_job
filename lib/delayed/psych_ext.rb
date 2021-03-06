if defined?(ActiveRecord)
  ActiveRecord::Base.class_eval do
    if instance_methods.include?(:encode_with)
      def encode_with_override(coder)
        encode_with_without_override(coder)
        coder.tag = "!ruby/object:#{self.class.name}"
      end
      alias_method :encode_with_without_override, :encode_with
      alias_method :encode_with, :encode_with_override
    else
      def encode_with(coder)
        coder["attributes"] = attributes
        coder.tag = "!ruby/object:#{self.class.name}"
      end
    end
  end
end

module Delayed
  class PerformableMethod
    # serialize to YAML
    def encode_with(coder)
      coder.map = {
        'object' => object,
        'method_name' => method_name,
        'args' => args
      }
    end
  end
end

module Psych
  module Visitors
    class ToRuby
      def visit_Psych_Nodes_Mapping_with_class(object) # rubocop:disable CyclomaticComplexity, MethodName
        return revive(Psych.load_tags[object.tag], object) if Psych.load_tags[object.tag]

        case object.tag
        when /^!ruby\/ActiveRecord:(.+)$/
          klass = resolve_class(Regexp.last_match[1])
          payload = Hash[*object.children.collect { |c| accept c }]
          id = payload['attributes'][klass.primary_key]
          begin
            klass.unscoped.find(id)
          rescue ActiveRecord::RecordNotFound
            raise Delayed::DeserializationError
          end
        when /^!ruby\/Mongoid:(.+)$/
          klass = resolve_class(Regexp.last_match[1])
          payload = Hash[*object.children.collect { |c| accept c }]
          begin
            klass.find(payload['attributes']['_id'])
          rescue Mongoid::Errors::DocumentNotFound
            raise Delayed::DeserializationError
          end
        when /^!ruby\/DataMapper:(.+)$/
          klass = resolve_class(Regexp.last_match[1])
          payload = Hash[*object.children.collect { |c| accept c }]
          begin
            primary_keys = klass.properties.select { |p| p.key? }
            key_names = primary_keys.collect { |p| p.name.to_s }
            klass.get!(*key_names.collect { |k| payload['attributes'][k] })
          rescue DataMapper::ObjectNotFoundError
            raise Delayed::DeserializationError
          end
        else
          visit_Psych_Nodes_Mapping_without_class(object)
        end
      end
      alias_method_chain :visit_Psych_Nodes_Mapping, :class

      def resolve_class_with_constantize(klass_name)
        klass_name.constantize
      rescue
        resolve_class_without_constantize(klass_name)
      end
      alias_method_chain :resolve_class, :constantize
    end
  end
end
