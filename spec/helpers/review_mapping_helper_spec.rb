require 'rails_helper'

describe 'ReviewMappingHelper', :type => :helper do
  describe "#construct_sentiment_query" do
    it "should not return nil" do
      expect(helper.construct_sentiment_query(1,"Text")).not_to eq(nil)
    end
  end
end