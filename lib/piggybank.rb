# Part of the Piggybank library for interacting with COINS
# Copyright 2014 Board of Regents of the University of Wisconsin System
# Released under the MIT license; see LICENSE

##
# Piggybank is a small library to allow scripts to interact with MRN's
# COINS database for neuroimaging data.
#
# At its heart, it's a little mechanize-based scraper and a boatload
# of regular expressions.

require 'mechanize'
require 'uri'
require 'json'

class Piggybank
  DEFAULT_URL = "https://chronus.mrn.org"
  attr_accessor :agent
  attr_accessor :url_base

  def initialize(agent=nil, url_base=DEFAULT_URL)
    @agent = agent
    @url_base = url_base
    if @agent.nil?
      @agent = Mechanize.new
      @agent.user_agent_alias = 'Mac Firefox'
    end
  end

  class << self
    def logged_in_from_key(key, agent=nil, url_base=DEFAULT_URL)
      pb = self.new(agent, url_base)
      pb.login_from_key(key)
      pb
    end

    def logged_in_from_file(key_file=nil, agent=nil, url_base=DEFAULT_URL)
      key_file ||= File.join(ENV['HOME'], "niGet_sh.key")
      key = File.read(key_file).strip()
      pb = self.new(agent, url_base)
      pb.login_from_key(key)
      pb
    end
  end

  def login_from_key(key)
    form_action = "#{@url_base}/cas/shlogin.php"
    page = @agent.post form_action, {
      :uk => URI.decode_www_form_component(key)
    }
    page
  end

  def login(username, password)
    # This method raises a warning from coins but still seems to work. There's
    # a more complex version that uses the normal login page but it is
    # quite horrible, with randomly-named form parameters written by
    # javascript.
    form_action = "#{@url_base}/micis/remote/loginPopupValidation.php"
    page = @agent.post form_action, {
      :username => username,
      :pwd => password,
      :appName => "MICIS"
    }
    page
  end

  def logged_in?
    act = StudyListAction.new(self)
    act.get
    !(act.redirected_to_login?)
  end

  def list_studies
    act = StudyListAction.new(self)
    act.get
  end

  def list_subjects(study_id)
    act = SubjectListAction.new(self)
    act.get(study_id)
  end

  def get_demographics_by_ursi(ursi)
    s = Subject.new
    s.ursi = ursi
    s = get_demographics(s)
    s
  end

  def get_demographics(subject)
    act = SubjectViewAction.new(self)
    act.get(subject)
  end

  def list_instruments(study_id)
    act = InstrumentListAction.new(self)
    act.get(study_id)
  end

  def get_assessments(study_id, instrument_id)
    act = AssessmentDownloadAction.new(self)
    pieces = AssessmentDownloadAction::DEFAULT_OUTPUT_PIECES.merge({
      "instrumentId" => instrument_id.to_s,
      "studyId" => study_id.to_s
      })
    act.get({"outputPieces" => [pieces]})
  end

  module ActionUtils
    def strip_quotes(str)
      str.gsub(/\A'|'\Z/, '')
    end
  end

  class Action
    include Piggybank::ActionUtils
    def initialize(piggybank)
      @piggybank = piggybank
      @agent = piggybank.agent
    end

    def redirected_to_login?
      @agent.page.body.match "#{@piggybank.url_base}/cas/login.php"
    end

  end

  class StudyListAction < Action
    def get
      p = @agent.get "#{@piggybank.url_base}/micis/study/index.php?action=list"
      # Yields something like "[[stuff]]"
      study_matches = p.body.match(/parent\.list=\[(.*?)\];/)
      study_matches or return nil
      study_list = study_matches[1]
      study_arrays = study_list.scan(/\[(.*?)\]/)
      study_arrays.map {|ary|
        study_bits = ary[0].split(",").map {|bit| strip_quotes(bit)}
        s = Piggybank::Study.new
        s.study_number = study_bits[0]
        s.irb_number = study_bits[1]
        s.status = study_bits[3]
        # The name and id are in a string that looks like
        # WISCDEMO2^javascript:parent.loadPage(\"https://chronus.mrn.org/micis/study/index.php?action=view&study_id=6160\")^pageIframe
        more_bits = study_bits[2].split('^')
        s.name = more_bits[0]
        s.study_id = more_bits[1].match(/study_id=(\d+)/)[1]
        s
      }
    end
  end

  class SubjectListAction < Action
    def get(study_id)
      p = @agent.get "#{@piggybank.url_base}/micis/subject/index.php?action=getStudy&study_id=#{study_id}&DoGetStudySubjects=true"
      subject_data_ary = p.body.scan(/\[('M[^\]]+)\]/)
      subject_data_ary.map {|sda|
        d = sda[0]
        s = Piggybank::Subject.new
        s.ursi = d[/M\d+/] # URSIs start with M
        s
      }
    end
  end

  class SubjectViewAction < Action

    FIELD_MAP = {
      "First Name" => :first_name,
      "Middle Name" => :middle_name,
      "Last Name" => :last_name,
      "Suffix" => :suffix,
      "Birth Date" => :birth_date,
      "Gender" => :gender,
      "Address Line 1" => :address_1,
      "Address Line 2" => :address_2,
      "City" => :city,
      "State" => :state,
      "Zip" => :zip,
      "Country" => :country,
      "Email Address" => :email,
      "Notes" => :notes,
      "Phone 1" => :phone_1,
      "Phone 2" => :phone_2,
    }
    def get(subject)
      p = @agent.get "#{@piggybank.url_base}/micis/subject/index.php?action=view&ursi=#{subject.ursi_key}"
      data_hash = Hash[p.search("td.frmLabel").map {|result|
        [result.text, result.next_element.text]
      }]
      out = subject.dup
      FIELD_MAP.each do |coins_field, pb_field|
        out.send "#{pb_field}=", data_hash[coins_field]
      end
      out
    end
  end

  class InstrumentListAction < Action
    def get(study_id)
      p = @agent.get "#{@piggybank.url_base}/micis/remote/getStudyData.php", {
        :type => "instruments",
        :id => study_id
      }
      JSON.parse(p.body)
    end
  end

  class AssessmentDownloadAction < Action

    DEFAULT_OUTPUT_PIECES = {
      "instrumentId" => "0",
      "visitId" => "0",
      "visitLabel" => "All Visits",
      "studyId" => "0"
    }

    DEFAULT_OPTIONS = {
      "collapseseries" => true,
      "erpscans" => false,
      "fieldSeparator" => "u0009",
      "includequestdesc" => "yes",
      "includeAsmtMeta" => "yes",
      "lineSeparator" => "u000a",
      "missingDataVal" => "-1001",
      "dontKnowVal" => "-1002",
      "maxrecordsreturn" => 500,
      "optCollapseByURSI" => false,
      "optMostCompleteEntries" => false,
      "orientation" => "crossCollapse",
      "scanOrientation" => "normalOneCell",
      "outputPieces" => [{
      }],
      "outputScanPieces" => [],
      "qPieces" => [],
      "returnall" => true,
      "scanPieces" => [],
      "textqualifier" => "\"",
      "subjectType" => 0,
      "visitorientation" => "updown",
      "questFormatSegInt" => true,
      "questFormatSegInst" => true,
      "questFormatEC" => false,
      "questFormatSiteCt" => false,
      "questFormatSourceCt" => false,
      "questFormatRaterCt" => false,
      "questFormatQuesInst" => true,
      "questFormatDrop1" => true,
      "allQueriedFields" => false,
      "limitStSrcRt" => true,
      "printFirstOnlyAsmt" => false,
      "includeRespLabel" => false,
      "showMissingAsPd" => false,
      "asmtBoolLogic" => false,
      "scanBoolLogic" => false,
      "showOnlyDataUrsis" => false,
      "queryHasRecords" => false,
      "optCentries" => false
    }

    def get(options = {})
      puts "WARNING: This method does not work. Maybe we can figure out why."
      options = DEFAULT_OPTIONS.merge options
      p = @agent.get "#{@piggybank.url_base}/micis/downloadcsv.php", {
        :action => 1,
        :ds => "scansorassessments",
        :q => JSON.dump(options)
      }
      p.body
    end
  end

  class Error < RuntimeError

  end

end



require 'piggybank/study'
require 'piggybank/subject'