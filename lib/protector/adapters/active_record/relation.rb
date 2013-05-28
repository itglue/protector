module Protector
  module Adapters
    module ActiveRecord
      module Relation
        extend ActiveSupport::Concern

        included do
          include Protector::DSL::Base

          alias_method_chain :exec_queries, :protector
          alias_method_chain :eager_loading?, :protector

          attr_accessor :eager_loadable_when_protected

          # AR 3.2 workaround. Come on, guys... SQL parsing :(
          unless method_defined?(:references_values)
            def references_values
              tables_in_string(to_sql)
            end
          end

          unless method_defined?(:joins!)
            def joins!(*args)
              self.joins_values += args
            end
          end
        end

        def protector_meta
          # We don't seem to require columns here as well
          # @klass.protector_meta.evaluate(@klass, @protector_subject, @klass.column_names)
          @klass.protector_meta.evaluate(@klass, @protector_subject)
        end

        def unscoped
          super.restrict!(@protector_subject)
        end

        def count(*args)
          super || 0
        end

        def sum(*args)
          super || 0
        end

        def calculate(*args)
          return super unless @protector_subject
          merge(protector_meta.relation).unrestrict!.calculate *args
        end

        def exists?(*args)
          return super unless @protector_subject
          merge(protector_meta.relation).unrestrict!.exists? *args
        end

        def exec_queries_with_protector(*args)
          return exec_queries_without_protector unless @protector_subject

          subject  = @protector_subject
          relation = merge(protector_meta.relation).unrestrict!

          # We can not allow join-based eager loading for scoped associations
          # since actual filtering can differ for host model and joined relation.
          # Therefore we turn all `includes` into `preloads`.
          # 
          # Note that `includes_values` shares reference across relation diffs so
          # it has to be COPIED not modified
          relation.includes_values = relation.includes_values.select do |i|
            klass = @klass.reflect_on_association(i).klass
            meta  = klass.protector_meta.evaluate(klass, subject)

            # We leave unscoped restrictions as `includes`
            # but turn scoped ones into `preloads`
            unless meta.scoped?
              true
            else
              # AR 3.2 Y U NO HAVE BANG RELATION MODIFIERS
              relation.joins!(i.to_sym) if references_values.include?(i.to_s)
              relation.preload_values << i
              false
            end
          end

          # We should explicitly allow/deny eager loading now that we know
          # if we can use it
          relation.eager_loadable_when_protected = relation.includes_values.any?

          # Preserve associations from internal loading. We are going to handle that
          # ourselves respecting security scopes FTW!
          associations, relation.preload_values = relation.preload_values, []

          @records = relation.send(:exec_queries).each{|r| r.restrict!(subject)}

          # Now we have @records restricted properly so let's preload associations!
          associations.each do |a|
            ::ActiveRecord::Associations::Preloader.new(@records, a).run
          end

          @loaded = true
          @records
        end

        def eager_loading_with_protector?
          @eager_loadable_when_protected.nil? ? eager_loading_without_protector?
                                              : !!@eager_loadable_when_protected
        end
      end
    end
  end
end