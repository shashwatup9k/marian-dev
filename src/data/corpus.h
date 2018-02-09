#pragma once

#include <fstream>
#include <iostream>
#include <random>

#include <boost/algorithm/string.hpp>
#include <boost/iterator/iterator_facade.hpp>

#include "common/config.h"
#include "common/definitions.h"
#include "common/file_stream.h"
#include "data/alignment.h"
#include "data/batch.h"
#include "data/corpus_base.h"
#include "data/dataset.h"
#include "data/vocab.h"

namespace marian {
namespace data {

class Corpus : public CorpusBase {
private:
  std::vector<UPtr<TemporaryFile>> tempFiles_;

  std::mt19937 g_;
  std::vector<size_t> ids_;

  void shuffleFiles(const std::vector<std::string>& paths);

public:
  Corpus(Ptr<Config> options, bool translate = false);

  Corpus(std::vector<std::string> paths,
         std::vector<Ptr<Vocab>> vocabs,
         Ptr<Config> options,
         size_t maxLength = 0);

  /**
   * @brief Iterates sentence tuples in the corpus.
   *
   * A sentence tuple is skipped with no warning if any sentence in the tuple
   * (e.g. a source or target) is longer than the maximum allowed sentence
   * length in words unless the option "max-length-crop" is provided.
   *
   * @return A tuple representing parallel sentences.
   */
  sample next();

  void shuffle();

  void reset();

  iterator begin() { return iterator(this); }

  iterator end() { return iterator(); }

  std::vector<Ptr<Vocab>>& getVocabs() { return vocabs_; }

  batch_ptr toBatch(const std::vector<sample>& batchVector) {
    int batchSize = batchVector.size();

    std::vector<size_t> sentenceIds;

    std::vector<int> maxDims;
    for(auto& ex : batchVector) {
      if(maxDims.size() < ex.size())
        maxDims.resize(ex.size(), 0);
      for(size_t i = 0; i < ex.size(); ++i) {
        if(ex[i].size() > (size_t)maxDims[i])
          maxDims[i] = ex[i].size();
      }
      sentenceIds.push_back(ex.getId());
    }

    std::vector<Ptr<SubBatch>> subBatches;
    for(auto m : maxDims) {
      subBatches.emplace_back(New<SubBatch>(batchSize, m));
    }

    std::vector<size_t> words(maxDims.size(), 0);
    for(int i = 0; i < batchSize; ++i) {
      for(int j = 0; j < maxDims.size(); ++j) {
        for(int k = 0; k < batchVector[i][j].size(); ++k) {
          subBatches[j]->indices()[k * batchSize + i] = batchVector[i][j][k];
          subBatches[j]->mask()[k * batchSize + i] = 1.f;
          words[j]++;
        }
      }
    }

    for(size_t j = 0; j < maxDims.size(); ++j)
      subBatches[j]->setWords(words[j]);

    auto batch = batch_ptr(new batch_type(subBatches));
    batch->setSentenceIds(sentenceIds);

    if(options_->has("guided-alignment"))
      addAlignmentsToBatch(batch, batchVector);
    if(options_->has("data-weighting"))
      addWeightsToBatch(batch, batchVector);

    return batch;
  }

  // @TODO: check if can be removed
  void prepare() { }

private:
  void addAlignmentsToBatch(Ptr<CorpusBatch> batch,
                            const std::vector<sample>& batchVector) {
    int srcWords = batch->front()->batchWidth();
    int trgWords = batch->back()->batchWidth();
    int dimBatch = batch->getSentenceIds().size();
    std::vector<float> aligns(dimBatch * srcWords * trgWords, 0.f);

    for(int b = 0; b < dimBatch; ++b) {
      for(auto p : batchVector[b].getAlignment()) {
        int sid, tid;
        std::tie(sid, tid) = p;

        size_t idx = b + sid * dimBatch + tid * srcWords * dimBatch;
        aligns[idx] = 1.f;
      }
    }
    batch->setGuidedAlignment(aligns);
  }

  void addWeightsToBatch(Ptr<CorpusBatch> batch,
                         const std::vector<sample>& batchVector) {
    int dimBatch = batch->getSentenceIds().size();
    int trgWords = batch->back()->batchWidth();

    auto sentenceLevel
        = options_->get<std::string>("data-weighting-type") == "sentence";
    int s = sentenceLevel ? dimBatch : dimBatch * trgWords;
    std::vector<float> weights(s, 1.f);

    for(int b = 0; b < dimBatch; ++b) {
      if(sentenceLevel) {
        weights[b] = batchVector[b].getWeights().front();
      } else {
        size_t i = 0;
        for(auto& w : batchVector[b].getWeights()) {
          weights[b + i * dimBatch] = w;
          ++i;
        }
      }
    }

    batch->setDataWeights(weights);
  }
};
}
}
