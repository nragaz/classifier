Welcome to Classifier
=====================

Classifier is a general module to allow Bayesian and other types of classifications.

About this Fork
---------------

The goal is to reduce memory usage and make it possible to classify very large numbers of documents (600+) using LSI.

**Tidying:**

* GSL has been added as a dependency, and the gemspec is a file so that the gem can be installed from Github using Bundler.
* Some string extensions (clean_word_hash, word_hash) have been replaced with a new class, WordHash, to avoid adding too many methods to core classes.

**New features:**

* LSI can persist itself using [Sequel](http://sequel.rubyforge.org/). Pass a `:db` option to LSI::Classifier.new to specify a file path; otherwise, an in-memory database will be used.
* Memory usage is significantly reduced. Building an index for lots of large texts, however, still consumes a fair bit of RAM, but approximately 1/3 of previous.

**Syntax/usage changes:**

* Clean word hashes now exclude words that mix letters and numbers, and strip all punctuation including underscores.
* LSI instances can no longer be marshalled. Use database persistence instead.
* LSI no longer supports passing content as a block, because I couldn't see a  use-case.
* LSI no longer supports manipulating an item's categories as an array.

**Todo:**

* Enable flexible rules for word stemming / inclusion. e.g. Pass a block to WordHash to determine a valid word.
* Speed. The goal here is to persist everything that's not in use, because the matrices alone consume huge amounts of RAM. However, this means that many operations are slower than when all of the data is in RAM (it's faster than paging, though!). Is it possible to use the database's native functions at all to speed things up?
* Reduce matrix memory consumption. `build_reduced_matrix` immediately chews up 100s of MBs.

The existing tests pass, but if you find any new bugs or strange behaviour, please create a pull request.

Download
--------

* http://rubyforge.org/projects/classifier
* gem install classifier
* svn co http://rufy.com/svn/classifier/trunk

Dependencies
------------

If you install Classifier from source, you'll need to install Martin Porter's stemmer algorithm with RubyGems as follows:

    gem install ruby-stemmer

If you would like to speed up LSI classification by at least 10x, please install the following libraries:

* [GNU GSL](http://www.gnu.org/software/gsl)
* [rb-gsl](http://rb-gsl.rubyforge.org)

Notice that LSI will work without these libraries, but as soon as they are installed, Classifier will make use of them. No configuration changes are needed, we like to keep things ridiculously easy for you.

Bayes
=====

A Bayesian classifier by Lucas Carlson. Bayesian Classifiers are accurate, fast, and have modest memory requirements.

Usage
-----

    require 'classifier'
    b = Classifier::Bayes.new 'Interesting', 'Uninteresting'
    b.train_interesting "here are some good words. I hope you love them"
    b.train_uninteresting "here are some bad words, I hate you"
    b.classify "I hate bad words and you" # returns 'Uninteresting'
    
    require 'madeleine'
    m = SnapshotMadeleine.new("bayes_data") {
        Classifier::Bayes.new 'Interesting', 'Uninteresting'
    }
    m.system.train_interesting "here are some good words. I hope you love them"
    m.system.train_uninteresting "here are some bad words, I hate you"
    m.take_snapshot
    m.system.classify "I love you" # returns 'Interesting'

Using Madeleine, your application can persist the learned data over time.

Bayesian Classification
-----------------------

* http://www.process.com/precisemail/bayesian_filtering.htm
* http://en.wikipedia.org/wiki/Bayesian_filtering
* http://www.paulgraham.com/spam.html

LSI
===

A Latent Semantic Indexer by David Fayram. Latent Semantic Indexing engines
are not as fast or as small as Bayesian classifiers, but are more flexible, providing fast search and clustering detection as well as semantic analysis of the text that theoretically simulates human learning.

Usage
-----

    require 'classifier'
    lsi = Classifier::LSI.new
    strings = [ ["This text deals with dogs. Dogs.", :dog],
                ["This text involves dogs too. Dogs! ", :dog],
                ["This text revolves around cats. Cats.", :cat],
                ["This text also involves cats. Cats!", :cat],
                ["This text involves birds. Birds.",:bird ]]
    strings.each {|x| lsi.add_item x.first, x.last}
  
    lsi.search("dog", 3)
    # returns => ["This text deals with dogs. Dogs.", "This text involves dogs too. Dogs! ", 
    #             "This text also involves cats. Cats!"]

    lsi.find_related(strings[2], 2)
    # returns => ["This text revolves around cats. Cats.", "This text also involves cats. Cats!"]
  
    lsi.classify "This text is also about dogs!"
    # returns => :dog
  
Please see the Classifier::LSI documentation for more information. It is possible to index, search and classify
with more than just simple strings. 

Latent Semantic Indexing
------------------------

* http://www.c2.com/cgi/wiki?LatentSemanticIndexing
* http://www.chadfowler.com/index.cgi/Computing/LatentSemanticIndexing.rdoc
* http://en.wikipedia.org/wiki/Latent_semantic_analysis

Authors
=======

* Lucas Carlson  (mailto:lucas@rufy.com)
* David Fayram II (mailto:dfayram@gmail.com)
* Cameron McBride (mailto:cameron.mcbride@gmail.com)
* Nick Ragaz (mailto:nick.ragaz@gmail.com)

This library is released under the terms of the GNU LGPL. See LICENSE for more details.