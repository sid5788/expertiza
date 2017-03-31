module ReviewMappingHelper
  def create_report_table_header(headers = {})
    table_header = "<div class = 'reviewreport'>\
                    <table width='100% cellspacing='0' cellpadding='2' border='0'>\
                    <tr bgcolor='#CCCCCC'>"
    headers.each do |header, percentage|
      table_header += if percentage
                        "<th width = #{percentage}>\
                                        #{header.humanize}\
                                        </th>"
                      else
                        "<th>\
                                        #{header.humanize}\
                                        </th>"
                      end
    end
    table_header += "</tr>"
    table_header.html_safe
  end

  #
  # This constructs the query to be sent to the sentiment generation server
  #
  def construct_sentiment_query(id, text)
    review = {}
    review["id"] = id.to_s
    review["text"] = text
    review
  end

  #
  # This retrieves the response from the sentiment generation server
  #
  def retrieve_sentiment_response(review, first_try)
    if first_try
      response = HTTParty.post(
        'http://peerlogic.csc.ncsu.edu/sentiment/analyze_reviews_bulk',
        body: {"reviews" => [review]}.to_json,
        headers: {'Content-Type' => 'application/json'}
      )
    else
      # Send only the first sentence of the review for sentiment analysis
      text = review["text"].split('.')[0]
      reconstructed_review = construct_sentiment_query(review["id"], text)
      response = HTTParty.post(
        'http://peerlogic.csc.ncsu.edu/sentiment/analyze_reviews_bulk',
        body: {"reviews" => [reconstructed_review]}.to_json,
        headers: {'Content-Type' => 'application/json'}
      )
    end
    response
  end

  #
  # Creates sentiment hash with id of review and the results from sentiment generation server
  #
  def create_sentiment(id, sentiment_value)
    sentiment = {}
    sentiment["id"] = id
    sentiment["sentiment"] = sentiment_value
    sentiment
  end

  #
  # Handles error scenarios while retrieving sentiment value from sentiment server
  #
  def handle_sentiment_generation_retry(response, review)
    sentiment = {}
    case response.code
    when 200
      sentiment = create_sentiment(response.parsed_response["sentiments"][0]["id"], response.parsed_response["sentiments"][0]["sentiment"])
    else
      # Instead of checking for individual error response codes, have a generic code set for any server related error
      # For now the value representing any server error will be -500
      sentiment = create_sentiment(review["id"], "-500")
    end
    sentiment
  end

  #
  # Generates sentiment list for all the reviews
  #
  def generate_sentiment_list
    @sentiment_list = []
    @reviewers.each do |r|
      review = construct_sentiment_query(r.id, Response.concatenate_all_review_comments(@id, r).join(" "))
      response = retrieve_sentiment_response(review, true)
      # Retry in case of failure by sending only a single sentence for sentiment analysis.
      case response.code
      when 200
        @sentiment_list << create_sentiment(response.parsed_response["sentiments"][0]["id"], response.parsed_response["sentiments"][0]["sentiment"])
      else
        # Retry once in case of a failure
        @sentiment_list << handle_sentiment_generation_retry(retrieve_sentiment_response(review, false), review)
      end
    end
    @sentiment_list
  end

  #
  # Displays the value of sentiment
  #
  def display_sentiment_metric(id)
    hashed_sentiment = @sentiment_list.select {|sentiment| sentiment["id"] == id.to_s }
    value = hashed_sentiment[0]["sentiment"].to_f.round(2)
    metric = "Overall Sentiment: #{value}<br/>"
    metric.html_safe
  end

  #
  # for review report
  #
  def get_data_for_review_report(reviewed_object_id, reviewer_id, type, line_num)
    rspan = 0
    line_num += 1
    bgcolor = line_num.even? ? "#ffffff" : "#DDDDBB"
    (1..@assignment.num_review_rounds).each {|round| instance_variable_set("@review_in_round_" + round.to_s, 0) }

    response_maps = ResponseMap.where(["reviewed_object_id = ? AND reviewer_id = ? AND type = ?", reviewed_object_id, reviewer_id, type])
    response_maps.each do |ri|
      rspan += 1 if Team.exists?(id: ri.reviewee_id)
      responses = ri.response
      (1..@assignment.num_review_rounds).each do |round|
        instance_variable_set("@review_in_round_" + round.to_s, instance_variable_get("@review_in_round_" + round.to_s) + 1) if responses.exists?(round: round)
      end
    end
    [response_maps, bgcolor, rspan, line_num]
  end

  def get_team_name_color(response_map)
    team_name_color = Response.exists?(map_id: response_map.id) ? "green" : "red"
    review_graded_at = response_map.try(:reviewer).try(:review_grade).try(:review_graded_at)
    response_last_updated_at = response_map.try(:response).try(:last).try(:updated_at)
    team_name_color = "blue" if review_graded_at && response_last_updated_at && response_last_updated_at > review_graded_at
    team_name_color
  end

  def get_team_reviewed_link_name(max_team_size, response, reviewee_id)
    team_reviewed_link_name = if max_team_size == 1
                                TeamsUser.where(team_id: reviewee_id).first.user.fullname
                              else
                                Team.find(reviewee_id).name
                              end
    team_reviewed_link_name = "(" + team_reviewed_link_name + ")" if !response.empty? and !response.last.is_submitted?
    team_reviewed_link_name
  end

  def get_current_round_for_review_report(reviewer_id)
    user_id = Participant.find(reviewer_id).user.id
    topic_id = SignedUpTeam.topic_id(@assignment.id, user_id)
    @assignment.number_of_current_round(topic_id)
    @assignment.num_review_rounds if @assignment.get_current_stage(topic_id) == "Finished" || @assignment.get_current_stage(topic_id) == "metareview"
  end

  # varying rubric by round
  def get_each_round_score_awarded_for_review_report(reviewer_id, team_id)
    (1..@assignment.num_review_rounds).each {|round| instance_variable_set("@score_awarded_round_" + round.to_s, '-----') }
    (1..@assignment.num_review_rounds).each do |round|
      if @review_scores[reviewer_id] && @review_scores[reviewer_id][round] && @review_scores[reviewer_id][round][team_id] && @review_scores[reviewer_id][round][team_id] != -1.0
        instance_variable_set("@score_awarded_round_" + round.to_s, @review_scores[reviewer_id][round][team_id].inspect + '%')
      end
    end
  end

  def get_min_max_avg_value_for_review_report(round, team_id)
    [:max, :min, :avg].each {|metric| instance_variable_set('@' + metric.to_s, '-----') }
    if @avg_and_ranges[team_id] && @avg_and_ranges[team_id][round] && [:max, :min, :avg].all? {|k| @avg_and_ranges[team_id][round].key? k }
      [:max, :min, :avg].each do |metric|
        metric_value = @avg_and_ranges[team_id][round][metric].nil? ? '-----' : @avg_and_ranges[team_id][round][metric].round(0).to_s + '%'
        instance_variable_set('@' + metric.to_s, metric_value)
      end
    end
  end

  def sort_reviewer_by_review_volume_desc
    @reviewers.each do |r|
      r.overall_avg_vol,
      r.avg_vol_in_round_1,
      r.avg_vol_in_round_2,
      r.avg_vol_in_round_3 = Response.get_volume_of_review_comments(@assignment.id, r.id)
    end
    @reviewers.sort! {|r1, r2| r2.overall_avg_vol <=> r1.overall_avg_vol }
  end

  def display_volume_metric(overall_avg_vol, avg_vol_in_round_1, avg_vol_in_round_2, avg_vol_in_round_3)
    metric = "Avg. Volume: #{overall_avg_vol} <br/> ("
    metric += "1st: " + avg_vol_in_round_1.to_s if avg_vol_in_round_1 > 0
    metric += ", 2nd: " + avg_vol_in_round_2.to_s if avg_vol_in_round_2 > 0
    metric += ", 3rd: " + avg_vol_in_round_3.to_s if avg_vol_in_round_3 > 0
    metric += ")"
    metric.html_safe
  end

  def list_review_submissions(participant_id, reviewee_team_id, response_map_id)
    participant = Participant.find(participant_id)
    team = AssignmentTeam.find(reviewee_team_id)
    html = ''
    if !team.nil? and !participant.nil?
      review_submissions_path = team.path + "_review" + "/" + response_map_id.to_s
      files = team.submitted_files(review_submissions_path)
      if files and !files.empty?
        html += display_review_files_directory_tree(participant, files)
      end
    end
    html.html_safe
  end

  # Zhewei - 2017-02-27
  # This is for all Dr.Kidd's courses
  def calcutate_average_author_feedback_score(assignment_id, max_team_size, response_map_id, reviewee_id)
    review_response = ResponseMap.where(id: response_map_id).try(:first).try(:response).try(:last)
    author_feedback_avg_score = "-- / --"
    unless review_response.nil?
      user = TeamsUser.where(team_id: reviewee_id).try(:first).try(:user) if max_team_size == 1
      author = Participant.where(parent_id: assignment_id, user_id: user.id).try(:first) unless user.nil?
      feedback_response = ResponseMap.where(reviewed_object_id: review_response.id, reviewer_id: author.id).try(:first).try(:response).try(:last) unless author.nil?
      author_feedback_avg_score = feedback_response.nil? ? "-- / --" : "#{feedback_response.get_total_score} / #{feedback_response.get_maximum_score}"
    end
    author_feedback_avg_score
  end

  # Zhewei - 2016-10-20
  # This is for Dr.Kidd's assignment (806)
  # She wanted to quickly see if students pasted in a link (in the text field at the end of the rubric) without opening each review
  # Since we do not have hyperlink question type, we hacked this requirement
  # Maybe later we can create a hyperlink question type to deal with this situation.
  def list_hyperlink_submission(response_map_id, question_id)
    assignment = Assignment.find(@id)
    curr_round = assignment.try(:num_review_rounds)
    curr_response = Response.where(map_id: response_map_id, round: curr_round).first
    answer_with_link = Answer.where(response_id: curr_response.id, question_id: question_id).first if curr_response
    comments = answer_with_link.try(:comments)
    html = ''
    if comments and !comments.empty? and comments.start_with?('http')
      html += display_hyperlink_in_peer_review_question(comments)
    end
    html.html_safe
  end

  #
  # for author feedback report
  #
  #
  # varying rubric by round
  def get_each_round_review_and_feedback_response_map_for_feedback_report(author)
    @team_id = TeamsUser.team_id(@id.to_i, author.user_id)
    # Calculate how many responses one team received from each round
    # It is the feedback number each team member should make
    @review_response_map_ids = ReviewResponseMap.where(["reviewed_object_id = ? and reviewee_id = ?", @id, @team_id]).pluck("id")
    {1 => 'one', 2 => 'two', 3 => 'three'}.each do |key, round_num|
      instance_variable_set('@review_responses_round_' + round_num,
                            Response.where(["map_id IN (?) and round = ?", @review_response_map_ids, key]))
      # Calculate feedback response map records
      instance_variable_set('@feedback_response_maps_round_' + round_num,
                            FeedbackResponseMap.where(["reviewed_object_id IN (?) and reviewer_id = ?",
                                                       instance_variable_get('@all_review_response_ids_round_' + round_num), author.id]))
    end
    # rspan means the all peer reviews one student received, including unfinished one
    @rspan_round_one = @review_responses_round_one.length
    @rspan_round_two = @review_responses_round_two.length
    @rspan_round_three = @review_responses_round_three.nil? ? 0 : @review_responses_round_three.length
  end

  def get_certain_round_review_and_feedback_response_map_for_feedback_report(author)
    @feedback_response_maps = FeedbackResponseMap.where(["reviewed_object_id IN (?) and reviewer_id = ?", @all_review_response_ids, author.id])
    @team_id = TeamsUser.team_id(@id.to_i, author.user_id)
    @review_response_map_ids = ReviewResponseMap.where(["reviewed_object_id = ? and reviewee_id = ?", @id, @team_id]).pluck("id")
    @review_responses = Response.where(["map_id IN (?)", @review_response_map_ids])
    @rspan = @review_responses.length
  end

  #
  # for calibration report
  #
  def get_css_style_for_calibration_report(diff)
    # diff - difference between stu's answer and instructor's answer
    css_class = case diff.abs
                when 0
                  'c5'
                when 1
                  'c4'
                when 2
                  'c3'
                when 3
                  'c2'
                else
                  'c1'
                end
    css_class
  end
end
