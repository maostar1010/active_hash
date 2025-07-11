module ActiveHash
  class RecordNotFound < StandardError
    attr_reader :model, :primary_key, :id

    def initialize(message = nil, model = nil, primary_key = nil, id = nil)
      @primary_key = primary_key
      @model = model
      @id = id

      super(message)
    end
  end

  class ReservedFieldError < StandardError
  end

  class IdError < StandardError
  end

  class FileTypeMismatchError < StandardError
  end

  class Base
    class_attribute :_data, :dirty, :default_attributes, :scopes

    if Object.const_defined?(:ActiveModel)
      extend ActiveModel::Translation
      include ActiveModel::Conversion
    else
      def to_param
        id.present? ? id.to_s : nil
      end
    end

    class << self

      def cache_key
        if Object.const_defined?(:ActiveModel)
          model_name.cache_key
        else
          ActiveSupport::Inflector.tableize(self.name).downcase
        end
      end

      def primary_key
        "id"
      end

      def field_names
        @field_names ||= []
      end

      #
      # Useful for CSV integration needing column names as strings.
      #
      # @return [Array<String>] An array of column names as strings.
      #
      # @example Usage
      #  class Country < ActiveHash::Base
      #    fields :name, :code
      #  end
      #
      #  Country.column_names
      #  # => ["id", "name", "code"]
      #
      def column_names
        field_names.map(&:name)
      end

      def the_meta_class
        class << self
          self
        end
      end

      def compute_type(type_name)
        self
      end

      def pluralize_table_names
        true
      end

      def empty?
        false
      end

      def data
        _data
      end

      def data=(array_of_hashes)
        mark_dirty
        @records = nil
        reset_record_index
        self._data = array_of_hashes
        if array_of_hashes
          auto_assign_fields(array_of_hashes)
          array_of_hashes.each do |hash|
            insert new(hash)
          end
        end
      end

      def exists?(args = :none)
        if args.respond_to?(:id)
          record_index[args.id.to_s].present?
        elsif !args
          false
        elsif args == :none
          all.present?
        elsif args.is_a?(Hash)
          all.where(args).present?
        else
          all.where(id: args.to_i).present?
        end
      end

      def insert(record)
        @records ||= []
        record[:id] ||= next_id
        validate_unique_id(record) if dirty
        mark_dirty

        add_to_record_index({ record.id.to_s => @records.length })
        @records << record
      end

      def next_id
        max_record = all_in_process.max { |a, b| a.id <=> b.id }
        if max_record.nil?
          1
        elsif max_record.id.is_a?(Numeric)
          max_record.id.succ
        end
      end

      def all_in_process
        all
      end
      private :all_in_process

      def record_index
        @record_index ||= {}
      end

      def has_query_constraints?
        false
      end

      private :record_index

      def reset_record_index
        record_index.clear
      end

      private :reset_record_index

      def add_to_record_index(entry)
        record_index.merge!(entry)
      end

      private :add_to_record_index

      def validate_unique_id(record)
        raise IdError.new("Duplicate ID found for record #{record.attributes.inspect}") if record_index.has_key?(record.id.to_s)
      end

      private :validate_unique_id

      def create(attributes = {})
        record = new(attributes)
        record.save
        mark_dirty
        record
      end

      alias_method :add, :create

      def create!(attributes = {})
        record = new(attributes)
        record.save!
        record
      end

      def all(options = {})
        relation = ActiveHash::Relation.new(self, @records || [])
        relation = relation.where!(options[:conditions]) if options[:conditions]
        relation
      end

      delegate :where, :find, :find_by, :find_by!, :find_by_id, :count, :pluck, :ids, :pick, :first, :last, :order, to: :all

      def transaction
        yield
      rescue LocalJumpError => err
        raise err
      rescue StandardError => e
        unless Object.const_defined?(:ActiveRecord) && e.is_a?(ActiveRecord::Rollback)
          raise e
        end
      end

      def delete_all
        mark_dirty
        reset_record_index
        @records = []
      end

      def fields(*args)
        options = args.extract_options!
        args.each do |field|
          field(field, options)
        end
      end

      def field(field_name, options = {})
        field_name = field_name.to_sym
        validate_field(field_name)

        field_names << field_name

        add_default_value(field_name, options[:default]) if options.key?(:default)
        define_getter_method(field_name, options[:default])
        define_setter_method(field_name)
        define_interrogator_method(field_name)
        define_custom_find_method(field_name)
        define_custom_find_all_method(field_name)
      end

      def validate_field(field_name)
        field_name = field_name.to_sym
        if [:attributes].include?(field_name)
          raise ReservedFieldError.new("#{field_name} is a reserved field in ActiveHash.  Please use another name.")
        end
      end

      private :validate_field

      def respond_to?(method_name, include_private=false)
        super ||
          begin
            config = configuration_for_custom_finder(method_name)
            config && config[:fields].all? do |field|
              field_names.include?(field.to_sym) || field.to_sym == :id
            end
          end
      end

      def method_missing(method_name, *args)
        return super unless respond_to? method_name

        config = configuration_for_custom_finder(method_name)
        attribute_pairs = config[:fields].zip(args)
        matches = all.select { |base| attribute_pairs.all? { |field, value| base.send(field).to_s == value.to_s } }

        if config[:all?]
          matches
        else
          result = matches.first
          if config[:bang?]
            result || raise(RecordNotFound, "Couldn\'t find #{name} with #{attribute_pairs.collect { |pair| "#{pair[0]} = #{pair[1]}" }.join(', ')}")
          else
            result
          end
        end
      end

      def configuration_for_custom_finder(finder_name)
        if finder_name.to_s.match(/^find_(all_)?by_(.*?)(!)?$/) && !($1 && $3)
          {
            :all? => !!$1,
            :bang? => !!$3,
            :fields => $2.split('_and_')
          }
        end
      end

      private :configuration_for_custom_finder

      def add_default_value field_name, default_value
        self.default_attributes ||= {}
        self.default_attributes[field_name] = default_value
      end

      private :add_default_value

      def define_getter_method(field, default_value)
        unless instance_methods.include?(field)
          define_method(field) do
            attributes[field].nil? ? default_value : attributes[field]
          end
        end
      end

      private :define_getter_method

      def define_setter_method(field)
        method_name = :"#{field}="
        unless instance_methods.include?(method_name)
          define_method(method_name) do |new_val|
            @attributes[field] = new_val
          end
        end
      end

      private :define_setter_method

      def define_interrogator_method(field)
        method_name = :"#{field}?"
        unless instance_methods.include?(method_name)
          define_method(method_name) do
            send(field).present?
          end
        end
      end

      private :define_interrogator_method

      def define_custom_find_method(field_name)
        method_name = :"find_by_#{field_name}"
        unless singleton_methods.include?(method_name)
          the_meta_class.instance_eval do
            define_method(method_name) do |*args|
              args.extract_options!
              identifier = args[0]
              all.detect { |record| record.send(field_name) == identifier }
            end
          end
        end
      end

      private :define_custom_find_method

      def define_custom_find_all_method(field_name)
        method_name = :"find_all_by_#{field_name}"
        unless singleton_methods.include?(method_name)
          the_meta_class.instance_eval do
            unless singleton_methods.include?(method_name)
              define_method(method_name) do |*args|
                args.extract_options!
                identifier = args[0]
                all.select { |record| record.send(field_name) == identifier }
              end
            end
          end
        end
      end

      private :define_custom_find_all_method

      def auto_assign_fields(array_of_hashes)
        (array_of_hashes || []).inject([]) do |array, row|
          row.symbolize_keys!
          row.keys.each do |key|
            unless key.to_s == "id"
              array << key
            end
          end
          array
        end.uniq.each do |key|
          field key
        end
      end

      private :auto_assign_fields

      # Needed for ActiveRecord polymorphic associations
      def base_class
        ActiveHash::Base
      end

      # Needed for ActiveRecord polymorphic associations(rails/rails#32148)
      def polymorphic_name
        base_class.name
      end

      # Needed for ActiveRecord since rails/rails#47664
      def composite_primary_key?
        false
      end

      def reload
        reset_record_index
        self.data = _data
        mark_clean
      end

      private :reload

      def mark_dirty
        self.dirty = true
      end

      private :mark_dirty

      def mark_clean
        self.dirty = false
      end

      private :mark_clean

      def scope(name, body)
        raise ArgumentError, 'body needs to be callable' unless body.respond_to?(:call)

        self.scopes ||= {}
        self.scopes[name] = body

        the_meta_class.instance_eval do
          define_method(name) do |*args|
            instance_exec(*args, &body)
          end
        end
      end

    end

    def initialize(attributes = {})
      attributes.symbolize_keys!
      @attributes = attributes
      attributes.dup.each do |key, value|
        send "#{key}=", value
      end
      yield self if block_given?
    end

    def attributes
      if self.class.default_attributes
        (self.class.default_attributes.merge @attributes).freeze
      else
        @attributes
      end
    end

    def [](key)
      attributes[key]
    end

    def _read_attribute(key)
      attributes[key.to_sym]
    end
    alias_method :read_attribute, :_read_attribute

    def []=(key, val)
      @attributes[key] = val
    end

    def id
      attributes[:id] ? attributes[:id] : nil
    end

    def id=(id)
      @attributes[:id] = id
    end

    alias quoted_id id

    def new_record?
      !self.class.all.include?(self)
    end

    def destroyed?
      false
    end

    def persisted?
      self.class.all.map(&:id).include?(id)
    end

    def readonly?
      true
    end

    def eql?(other)
      other.instance_of?(self.class) and not id.nil? and (id == other.id)
    end

    alias == eql?

    def hash
      id.hash
    end

    def cache_key
      case
        when new_record?
          "#{self.class.cache_key}/new"
        when timestamp = self[:updated_at]
          if ActiveSupport::VERSION::MAJOR < 7
            "#{self.class.cache_key}/#{id}-#{timestamp.to_s(:number)}"
          else
            "#{self.class.cache_key}/#{id}-#{timestamp.to_fs(:number)}"
          end
        else
          "#{self.class.cache_key}/#{id}"
      end
    end

    def errors
      obj = Object.new

      def obj.[](key)
        []
      end

      def obj.full_messages()
        []
      end

      obj
    end

    def save(*args)
      unless self.class.exists?(self)
        self.class.insert(self)
      end
      true
    end

    alias save! save

    def valid?
      true
    end

    def marked_for_destruction?
      false
    end

  end
end
