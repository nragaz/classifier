# Author::   David Fayram  (mailto:dfayram@lensmen.net)
# Copyright:: Copyright (c) 2005 David Fayram II
# License::  LGPL

begin
  # to test the native vector class, try `rake test NATIVE_VECTOR=true`
  raise LoadError if ENV['NATIVE_VECTOR'] == "true"

  # requires http://rb-gsl.rubyforge.org/ (gem install gsl)
  require 'gsl'
  require 'classifier/extensions/vector_serialize'
  $GSL = true

rescue LoadError
  warn "Notice: for 10x faster LSI support, please install http://rb-gsl.rubyforge.org/ (gem install gsl)"
  require 'classifier/extensions/vector'
end

require 'sequel'

require 'classifier/lsi/migrate'
require 'classifier/lsi/content_node'
require 'classifier/lsi/word_list'

module Classifier

  # This class implements a Latent Semantic Indexer, which can search, classify 
  # and cluster data based on underlying semantic relations. For more 
  # information on the algorithms used, please consult
  # Wikipedia[http://en.wikipedia.org/wiki/Latent_Semantic_Indexing].
  class LSI
    attr_reader   :db, :word_list
    
    # Create a fresh index.
    # If you want to call #build_index manually, use
    #    Classifier::LSI.new :auto_rebuild => false
    # 
    # If you want to work with data on disk in an sqlite database, pass the
    # absolute path to a .sqlite file as options[:db]. Note that you need
    # to handle deleting an invalid file yourself in a rescue block.
    def initialize(options = {})
      @db = Sequel.sqlite(options[:db])
      migrate
      
      unless self.version
        self.version = 0
        self.built_at_version = -1
        self.auto_rebuild = options.has_key?(:auto_rebuild) ? 
          options[:auto_rebuild] : true
      end
      
      @nodes = db[:content_nodes].select(:id).all.map { |n|
        ContentNode.new self, n[:id]
      }
      @word_list = WordList.new(self)
    end
    
    # Returns true if the index needs to be rebuilt.  The index needs
    # to be built after all informaton is added, but before you start
    # using it for search, classification and cluster detection.
    def needs_rebuild?
      @db[:content_nodes].count > 1 && self.version != self.built_at_version
    end
    
    [:version, :built_at_version, :auto_rebuild].each do |setting|
      define_method setting do
        val =
          instance_variable_get("@#{setting}") ||
          @db[:settings].filter(:name => setting.to_s).map { |r| r[:val] }.first
        
        setting == :auto_rebuild && val.is_a?(Fixnum) ? val == 1 : val
      end
      
      define_method "#{setting}=" do |val|
        ins = setting == :auto_rebuild ? (val ? 1 : 0) : val
        filter = { :name => setting.to_s }
        
        if @db[:settings].filter(filter).count > 0
          @db[:settings].filter(filter).update :val => ins
        else
          @db[:settings].insert filter.merge(:val => ins)
        end
        
        instance_variable_set("@#{setting}", val)
      end
    end
    
    # List all items or find a specific item by its key.
    def items( key=nil )
      if key
        id = ContentNode.find(db, key).map { |c| c[:id] }.first
        @nodes.detect { |n| n.id == id }
      else
        @nodes
      end
    end
    
    # Adds an item to the index. item is assumed to be a string, but 
    # any item may be indexed so long as it responds to #to_s or if
    # you provide an optional block explaining how the indexer can 
    # fetch fresh string data. This optional block is passed the item,
    # so the item may only be a reference to a URL or file name.
    # 
    # For example:
    #  lsi = Classifier::LSI.new
    #  lsi.add_item "This is just plain text", :categories => "Plain"
    #
    def add_item( item, options={}, *old_categories )
      # for backwards compatibility with item, *categories syntax:
      unless options.is_a? Hash
        options = { :categories => [*options] + [*old_categories] }
      end
      
      node = ContentNode.new( self, item, options )
      @nodes << node
      
      self.version += 1
      build_index if self.auto_rebuild
      
      node
    end
    
    # A less flexible shorthand for add_item that assumes 
    # you are passing in a string with no categorries. item
    # will be duck typed via to_s.
    def <<( item )
      add_item item
    end
    
    # Removes an item from the database, if it is indexed.
    def remove_item( item_key )
      node = nil
      idx = nil
      
      @nodes.each { |n| node = n if n.key == item_key.to_s }
      
      raise "Could not find node for #{item_key}" unless node
      
      node.destroy
      @nodes.delete(node)
      
      self.version += 1
      build_index if self.auto_rebuild
    end
    
    # Return all categories in this classifier.
    def categories
      db[:categories].all.map { |c| c[:name] }.sort
    end
    
    # Returns the categories for a given indexed items. You are free to add and 
    # remove items from this as you see fit. It does not invalidate an index to
    # change its categories.
    def categories_for( item_key )
      items( item_key ).categories
    end
    
    # This function rebuilds the index if needs_rebuild? returns true.
    # For very large document spaces, this indexing operation may take some
    # time to complete, so it may be wise to place the operation in another 
    # thread. 
    #
    # As a rule, indexing will be fairly swift on modern machines until
    # you have well over 500 documents indexed, or have an incredibly diverse 
    # vocabulary for your documents. 
    #
    # The optional parameter "cutoff" is a tuning parameter. When the index is
    # built, a certain number of s-values are discarded from the system. The 
    # cutoff parameter tells the indexer how many of these values to keep.
    # A value of 1 for cutoff means that no semantic analysis will take place,
    # turning the LSI class into a simple vector search engine.
    def build_index( cutoff=0.75 )
      return unless needs_rebuild?
      
      word_list.update_dimensions
      
      matrix = profile('Matrix') { build_reduced_matrix(cutoff) }
      if $GSL
        profile('Vectors') {
          matrix.size[1].times do |col|
            vec = GSL::Vector.alloc( matrix.column(col) ).row
            @nodes[col].lsi_vector = vec
            @nodes[col].lsi_norm = vec.normalize
          end
        }
      else
        matrix.row_size.times do |col|
          if @nodes[col]
            @nodes[col].lsi_vector = matrix.column(col)
            @nodes[col].lsi_norm = matrix.column(col).normalize
          end
        end
      end
      
      self.built_at_version = self.version
    end
    
    # This method returns max_chunks entries, ordered by their average semantic 
    # rating. Essentially, the average distance of each entry from all other
    # entries is calculated, the highest are returned.
    #
    # This can be used to build a summary service, or to provide more 
    # information about your dataset's general content. For example, if you were 
    # to use categorize on the results of this data, you could gather
    # information on what your dataset is generally about.
    def highest_relative_content( max=10 )
      return [] if needs_rebuild?
      
      avg_density = Hash.new
      @nodes.each do |node|
        avg_density[node.key] =
          proximity_array_for_content(node.content).inject(0.0) { |y,z| y+z[1] }
      end
      
      avg_density.keys.
        sort_by { |key| avg_density[key] }.
        map { |key| items(key).content }.
        reverse[0..max-1]
    end

    # This function is the primitive that find_related and classify 
    # build upon. It returns an array of 2-element arrays. The first element
    # of this array is a document key, and the second is its "score", defining
    # how "close" it is to other indexed items.
    # 
    # These values are somewhat arbitrary, having to do with the vector space
    # created by your content, so the magnitude is interpretable but not always
    # meaningful between indexes. 
    #
    # The parameter doc is the content to compare. If that content is not
    # indexed, you can pass an optional block to define how to create the 
    # text data. See add_item for examples of how this works. 
    def proximity_array_for_content( doc )
      return [] if needs_rebuild?
      
      content_node = node_for_content( doc )
      result = @nodes.map do |node|
        val = $GSL ?
          (content_node.search_vector * node.search_vector.col) :
          (Matrix[content_node.search_vector] * node.search_vector)[0]
        
        [node.key, val]
      end
      
      result.sort_by { |x| !x[1].nan? ? x[1] : 100_000_000 }.reverse
    end
    
    # Similar to proximity_array_for_content, this function takes similar
    # arguments and returns a similar array. However, it uses the normalized
    # calculated vectors instead of their full versions. This is useful when 
    # you're trying to perform operations on content that is much smaller than
    # the text you're working with. search uses this primitive.
    def proximity_norms_for_content( doc )
      return [] if needs_rebuild?

      content_node = node_for_content( doc )
      result = @nodes.collect do |node|
        val = $GSL ?
          content_node.search_norm * node.search_norm.col :
          (Matrix[content_node.search_norm] * node.search_norm)[0]
        
        [node.key, val]
      end
      
      result.sort_by { |x| !x[1].nan? ? x[1] : 100_000_000 }.reverse
    end 

    # This function allows for text-based search of your index. Unlike other 
    # functions like find_related and classify, search only takes short strings. 
    # It will also ignore factors like repeated words. It is best for short, 
    # google-like search terms. 
    # A search will first priortize lexical relationships, then semantic ones. 
    #
    # While this may seem backwards compared to the other LSI functions,
    # it is actually the same algorithm, just applied on a smaller document.
    def search( string, max_nearest=3 )
      return [] if needs_rebuild?
      
      proximity_norms_for_content( string ).map { |n| n[0] }[0..max_nearest-1]
    end

    # This function takes content and finds other documents
    # that are semantically "close", returning an array of documents sorted
    # from most to least relavant.
    # max_nearest specifies the number of documents to return. A value of 
    # 0 means that it returns all the indexed documents, sorted by relavence. 
    #
    # This is useful for identifing clusters in your document space. 
    # For example you may want to identify several "What's Related" items for 
    # weblog articles, or find paragraphs that relate to each other in an essay.
    def find_related( doc, max_nearest=3 )
      existing_key = ContentNode.find_key_by_content(db, doc)
      
      proximity_array_for_content( doc ).
        reject { |pair| pair[0] == existing_key }.
        map { |pair| pair[0] }[0..max_nearest-1]
    end

    # This function uses a voting system to categorize documents, based on 
    # the categories of other documents. It uses the same logic as the 
    # find_related function to find related documents, then returns the
    # most obvious category from this list. 
    #
    # cutoff signifies the number of documents to consider when clasifying 
    # text. A cutoff of 1 means that every document in the index votes on 
    # what category the document is in. This may not always make sense.
    def classify( doc, cutoff=0.30 )
      icutoff = (@nodes.size * cutoff).round
      carry = proximity_array_for_content( doc )[0..icutoff-1]
      votes = {}
      carry.each do |pair|
        categories = items( pair[0] ).categories
        categories.each do |category| 
          votes[category] ||= 0.0
          votes[category] += pair[1] 
        end
      end
      ranking = votes.keys.sort_by { |x| votes[x] }
      
      ranking[-1]
    end

    # Prototype, only works on indexed documents.
    # I have no clue if this is going to work, but in theory
    # it's supposed to.
    def highest_ranked_stems( doc, count=3 )
      node = node_for_content(doc)
      
      unless node.persisted?
        raise "Requested stem ranking on non-indexed content!"
      end
      
      arr = node.lsi_vector.to_a
      arr.sort.reverse[0..count-1].map { |x|
        @word_list.word_for_index arr.index(x)
      }
    end

    private
    
    def build_reduced_matrix( cutoff=0.75 )
      tda = @nodes.map { |node| node.generate_raw_vector }
      u, v, s =
        ( $GSL ? GSL::Matrix.alloc(*tda) : Matrix.rows(tda) ).trans.SV_decomp
      
      # TODO: Better than 75% term, please. :\
      s_cutoff = s.sort.reverse[(s.size * cutoff).round - 1]
      s.size.times { |ord| s[ord] = 0.0 if s[ord] < s_cutoff }
      
      # Reconstruct the term document matrix, only with reduced rank
      u * ($GSL ? GSL::Matrix : ::Matrix).diag( s ) * v.trans
    end
    
    def node_for_content( content )
      if ContentNode.find_by_content(db, content).count > 0
        return items( ContentNode.find_key_by_content(db, content) )
      end

      cn = ContentNode.new(self, content, :persist => false)
      cn.generate_raw_vector unless needs_rebuild?
      cn
    end
    
    def make_word_list
      @word_list = Hash[ @db[:words].all.map { |w| [ w[:stem], w[:id] ] } ]
    end
    
    def profile( msg, &block )
      t = Time.now
      result = block.call
      puts "#{msg}: #{Time.now - t}s" if ENV['VERBOSE']
      
      result
    end
  end
end