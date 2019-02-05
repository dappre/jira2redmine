require 'rexml/document'
require 'active_record'
require 'yaml'
require 'fileutils'
require File.expand_path('../../../config/environment', __FILE__) # Assumes that migrate_jira.rake is in lib/tasks/

# require 'byebug'

module JiraMigration
  include Nokogiri

  ############## Configuration mapping file. Maps Jira Entities to Redmine Entities. Generated on the first run.
  CONF_FILE = 'map_jira_to_redmine.yml'
  ############## Jira backup main xml file with all data
  ENTITIES_FILE = 'entities.xml'
  ############## Location of jira attachements
  JIRA_ATTACHMENTS_DIR = 'data/attachments'
  ############## Jira URL
  $JIRA_WEB_URL = nil
  ############## Project filter (ex: "MYPRJ" or "(MYPRJA|MYPRJB)"
  $JIRA_PRJ_FILTER = nil
  ############## Issue key filter (ex: '[^-]+-\d{1,2}' or '(MYPRJA-\d+|MYPRJB-\d{1,2})'
  $JIRA_KEY_FILTER = nil

  roles = Role.where(:builtin => 0).order('position ASC').all
  ROLE_MAPPING = {
    'admin'     => roles[0],
    'developer' => roles[1],
  }
  DEFAULT_ROLE = roles.last

  ################################
  # Base class for any JIRA object
  # It handle the default initialization from XML nodes
  # And the migration of any JIRA object into Redmine based on ActivRecord
  class BaseJira
    MAP = {}

    attr_reader :tag
    attr_accessor :new_record, :is_new

    def map
      self.class::MAP
    end

    def initialize(node)
      @tag = node
    end

    def self.parse(xpath)
      # Parse XML nodes into Hashes
      nodes = $doc.xpath(xpath).collect{|i|i}.sort{|a,b|a.attribute('id').to_s<=>b.attribute('id').to_s}
      puts "XML entities = #{nodes.size}"

      # Remove node if related project is not in the scope
      unless nodes.size == 0 || nodes[0]['project'].nil?
        nodes.delete_if{|node| $MAP_JIRA_PROJECT_ID_TO_KEY[node['project']].nil? }
      end

      # Remove node if related issue is not in the scope
      unless nodes.size == 0 || nodes[0]['issue'].nil?
        nodes.delete_if{|node| $MAP_JIRA_ISSUE_ID_TO_KEY[node['issue']].nil? }
      end
      puts "Filtered entities = #{nodes.size}"

      # Convert Hashes into objects
      objs = []
      nodes.each do |node|
        obj = self.new(node)
        objs.push(obj)
      end
      return objs
    end

    def method_missing(key, *args)
      if key.to_s.start_with?('jira_')
        attr = key.to_s.sub('jira_', '')
        return @tag[attr]
      end
      puts "Method missing: #{key}"
      abort
      #raise NoMethodError key
    end

    def run_all_redmine_fields
      ret = {}
      self.methods.each do |method_name|
        m = method_name.to_s
        if m.start_with?('red_')
          mm = m.to_s.sub('red_', '')
          ret[mm] = self.send(m)
        end
      end
      return ret
    end

    def migrate
      all_fields = self.run_all_redmine_fields()
      #pp('Saving:', all_fields)

      record = self.retrieve
      if record
        record.update_attributes(all_fields)
      else
        record = self.class::DEST_MODEL.new all_fields
        self.is_new = true
      end

      if self.respond_to?('before_save')
        self.before_save(record)
      end

      begin
        record.save!
      rescue ActiveRecord::RecordInvalid => invalid
        puts invalid.record.errors
        puts record.errors.details
        pp self
        pp record
        raise
      end

      record.reload

      self.map[self.jira_id] = record
      self.new_record = record
      if self.respond_to?('post_migrate')
        self.post_migrate(record, self.is_new)
      end
	  
      record.reload
      return record
    end

    def retrieve
      self.class::DEST_MODEL.find_by_name(self.jira_id)
    end
  end

  ###############################
  # Specific class for JIRA users
  class JiraUser < BaseJira
    DEST_MODEL = User
    MAP = {}
    ATTRF = {
      'jira_id'            => 12,
      'jira_name'          => -24,
      'jira_emailAddress'  => -32,
      'jira_firstName'     => -24,
      'jira_lastName'      => -32,
    }

    attr_accessor  :jira_emailAddress, :jira_name, :jira_firstName, :jira_lastName

    def initialize(node)
      super
      @jira_name = node['name'].to_s
    end

    def retrieve
      # Check mail address first, as it is more likely to match across systems
      user = self.class::DEST_MODEL.find_by_mail(self.jira_emailAddress)
      if !user
        user = self.class::DEST_MODEL.find_by_login(self.jira_name)
      end

      return user
    end

    def migrate
      super
      $MIGRATED_USERS_BY_NAME[self.jira_name] = self.new_record
    end

    # First Name, Last Name, E-mail, Password
    # here is the tranformation of Jira attributes in Redmine attribues
    def red_firstname
      self.jira_firstName
    end

    def red_lastname
      self.jira_lastName
    end

    def red_mail
      self.jira_emailAddress
    end

    def red_login
      self.jira_name
    end

    def red_status
  	  if (!self.jira_active.nil? && self.jira_active.to_s != '1')
  	    return 3 #locked user
  	  else
  	    return 1 #unlock by default
  	  end
	  end

	  def before_save(new_record)
      new_record.login = red_login
      if new_record.new_record?
        new_record.salt_password('Pa$$w0rd')
      end
    end

    def post_migrate(new_record, is_new)
      if is_new
        new_record.update_attribute(:must_change_passwd, true)
        new_record.reload
      end
    end
  end

  ################################
  # Specific class for JIRA groups
  class JiraGroup < BaseJira
    DEST_MODEL = Group
    MAP = {}
    ATTRF = { # Main attribute names with best display size
      'jira_id'            => 12,
      'jira_name'          => -24,
    }

    def initialize(node)
      super
      @jira_name = @tag['name'] || @tag['lowerGroupName']
    end

    def self.parse(xpath = '/*/Group')
      #<Group id="30" groupName="developers" lowerGroupName="developers" active="1" local="0" createdDate="2011-05-08 15:47:01.492" updatedDate="2011-05-08 15:47:01.492" type="GROUP" directoryId="1"/>
      objs = super(xpath)
      #<OSGroup id="10020" name="Devops"/>
      objs += super('/*/OSGroup') #if nodes.empty?
      puts "Objects size = #{objs.size}"
      return objs
    end

    def retrieve
      group = self.class::DEST_MODEL.find_by_lastname(self.red_name)
    end

    def red_name
      self.jira_name
    end
  end

  ##################################
  # Specific class for JIRA projects
  class JiraProject < BaseJira
    DEST_MODEL = Project
    MAP = {}
    ATTRF = { # Main attribute names with best display size
      'jira_id'            => 12,
      'jira_key'           => 16,
      'jira_name'          => -32,
    }

    attr_accessor :jira_project

    def self.parse(xpath = '/*/Project')
      objs = super(xpath)
      # Filter projects if required
      if !$JIRA_PRJ_FILTER.nil?
        objs.delete_if{|obj| obj.jira_key !~ /^#{$JIRA_PRJ_FILTER}$/ }
      end
      # Saving Jira id and key in a Map for later optimisation
      objs.each do |obj|
        $MAP_JIRA_PROJECT_ID_TO_KEY[obj.tag['id']] = obj.tag['key']
      end
      puts "Objects size = #{objs.size}"
      return objs
    end

    def retrieve
      self.class::DEST_MODEL.find_by_identifier(self.red_identifier)
    end

    def post_migrate(new_record, is_new)
      if !new_record.module_enabled?('issue_tracking')
        new_record.enabled_modules << EnabledModule.new(:name => 'issue_tracking')
      end
      $MIGRATED_ISSUE_TYPES.values.uniq.each do |issue_type|
        if !new_record.trackers.include?(issue_type)
          new_record.trackers << issue_type
        end
      end
      new_record.update_column(:is_public, false)
      new_record.reload
    end

    # here is the tranformation of Jira attributes in Redmine attribues
    def red_name
      self.jira_name
    end

    def red_description
      self.jira_name
    end

    def red_identifier
      ret = self.jira_key.downcase
      return ret
    end
  end

  ##################################
  # Specific class for JIRA versions
  class JiraVersion < BaseJira
    DEST_MODEL = Version
    MAP = {}
    ATTRF = { # Main attribute names with best display size
      'jira_id'            => 12,
      'jira_project'       => 12,
      'red_project'        => -32,
      'jira_name'          => -32,
    }

    def self.parse(xpath = '/*/Version')
      objs = super(xpath)
      puts "Objects size = #{objs.size}"
      return objs
    end

    def jira_marker
      marker = "FROM JIRA: #{$MAP_PROJECT_ID_TO_PROJECT_KEY[self.jira_project]}\n"
      if !$JIRA_WEB_URL.nil?
        marker = "FROM JIRA: \"#{$MAP_PROJECT_ID_TO_PROJECT_KEY[self.jira_project]}\":#{$JIRA_WEB_URL}/browse/#{$MAP_PROJECT_ID_TO_PROJECT_KEY[self.jira_project]}\n"
      end
      return marker 
    end

    def retrieve
      self.class::DEST_MODEL.find_by_name(self.jira_name)
    end

    def red_project
      # needs to return the Rails Project object
      JiraProject::MAP[self.jira_project]
    end

    def red_name
      self.jira_name
    end

    def red_description
      self.jira_description
    end

    def red_due_date
      if self.jira_releasedate
        Time.parse(self.jira_releasedate)
      end
    end

  end

  ####################################
  # Specific class for JIRA components (= issue categories in Redmine)
  class JiraComponent < BaseJira

    DEST_MODEL = IssueCategory
    MAP = {}
    ATTRF = { # Main attribute names with best display size
      'jira_id'            => 12,
      'red_project'        => 24,
      'red_name'           => -64,
      'jira_lead'          => -24,
    }

    def self.parse(xpath = '/*/Component')
      objs = super(xpath)
      puts "Objects size = #{objs.size}"
      return objs
    end

    def red_project
      # needs to return the Rails Project object
      JiraProject::MAP[self.jira_project]
    end

    def red_name
      JiraMigration.encode(self.jira_name[0, JiraMigration::limit_for(IssueCategory, 'name')])
    end

    def red_assigned_to_id
      JiraMigration.find_user_by_jira_name(self.jira_lead)
    end

    def retrieve
      self.class::DEST_MODEL.find_by_name(self.jira_name)
    end
  end

  #######################################
  # Specific class for JIRA custom fields
  class JiraCustomField < BaseJira

    DEST_MODEL = IssueCustomField
    MAP = {}
    ATTRF = { # Main attribute names with best display size
      'jira_id'            => 12,
      'jira_name'          => -24,
      'red_name'           => -24,
    }

    def initialize(node)
      super
    end

    def self.parse(xpath = '/*/CustomField')
      # TODO: implement CustomValue migration before uncommenting
      #objs = super(xpath)
      objs = []

      # Add JIRA key as Redmine custom field
      obj = self.new({
        'name'                   => 'Key',
        'customfieldtypekey'     => 'com.atlassian.jira.plugin.system.customfieldtypes:textfield',
        'customfieldsearcherkey' => 'com.atlassian.jira.plugin.system.customfieldtypes:textsearcher',
      })
      objs.push(obj)

      # Add JIRA environment as Redmine custom field
      obj = self.new({
        'name'                   => 'Environment',
        'customfieldtypekey'     => 'com.atlassian.jira.plugin.system.customfieldtypes:textarea',
        'customfieldsearcherkey' => 'com.atlassian.jira.plugin.system.customfieldtypes:textsearcher',
      })
      objs.push(obj)

      puts "Objects size = #{objs.size}"
      return objs
    end

    def red_name
      return JiraMigration.encode(self.jira_name[0, JiraMigration::limit_for(IssueCustomField, 'name')])
    end

    def red_field_format
      return $confs["custom_field_types"][self.jira_customfieldtypekey]
    end

    def retrieve
      self.class::DEST_MODEL.find_by_name(self.jira_name)
    end

    def post_migrate(new_record, is_new)
      if is_new
        new_record.trackers = Tracker.all
        JiraProject::MAP.each do |jira_project, red_project|
          new_record.projects << red_project
        end
        new_record.reload
      end
    end
  end

  ################################
  # Specific class for JIRA issues
  class JiraIssue < BaseJira
    DEST_MODEL = Issue
    MAP = {}
    ATTRF = {
      'jira_id'            => 12,
      'jira_key'           => -12,
      'red_tracker'        => -24,
      'jira_reporter'      => -24,
      'jira_assignee'      => -24,
    }

    attr_reader  :jira_summary, :jira_description, :jira_reporter, :jira_environment#, :jira_project

    def initialize(node)
      super
      if @tag.at('summary')
        @jira_summary = @tag.at('summary').text
      else
        @jira_summary = node['summary'].to_s
      end
      if @tag.at('description')
        @jira_description = @tag.at('description').text
      else
        @jira_description = node['description'].to_s
      end
      @jira_reporter = node['reporter'].to_s
      @jira_assignee = node['assignee'].to_s
      if @tag.at('environment')
        @jira_environment = @tag.at('environment').text
      else
        @jira_environment = node['environment'].to_s
      end
    end

    def self.parse(xpath = '/*/Issue')
      #objs = super(xpath)
      objs = []
      nodes = $doc.xpath('/*/Issue').collect{|i|i}.sort{|a,b|a.attribute('id').to_s<=>b.attribute('id').to_s}
      #nodes.collect{|i|i}.sort{|a,b|a.attribute('id').to_s<=>b.attribute('id').to_s}
      puts "XML entities = #{nodes.size}"
        
      # Process only relevant issues
      unless $JIRA_PRJ_FILTER.nil?
        nodes.delete_if{|i| i['key'] !~ /^#{$JIRA_PRJ_FILTER}\-\d+$/ }
      end
      unless $JIRA_KEY_FILTER.nil?
        nodes.delete_if{|i| i['key'] !~ /^#{$JIRA_KEY_FILTER}$/ }
      end
      puts "Filtered entities = #{nodes.size}"
      
      nodes.each do |node|
        $MAP_JIRA_ISSUE_ID_TO_KEY[node['id']] = node['key']
        issue = JiraIssue.new(node)
        objs.push(issue)
      end

      puts "Objects size = #{objs.size}"
      return objs
    end

    def jira_marker
      marker = "FROM JIRA: #{self.jira_key}"
      if !$JIRA_WEB_URL.nil?
        marker = "FROM JIRA: \"#{self.jira_key}\":#{$JIRA_WEB_URL}/browse/#{self.jira_key}"
      end
      return marker 
    end

    def retrieve
      Issue.where("description Like '#{self.jira_marker}%'").first()
    end

    def red_project
      # needs to return the Rails Project object
      JiraProject::MAP[self.jira_project]
    end

    def red_fixed_version
      path = "/*/NodeAssociation[@sourceNodeId=\"#{self.jira_id}\" and @sourceNodeEntity=\"Issue\" and @sinkNodeEntity=\"Version\" and @associationType=\"IssueFixVersion\"]"
      assocs = JiraMigration.get_list_from_tag(path)
      versions = []
      assocs.each do |assoc|
        version = JiraVersion::MAP[assoc["sinkNodeId"]]
        versions.push(version)
      end
      versions.last
    end

    def red_category
      path = "/*/NodeAssociation[@sourceNodeId=\"#{self.jira_id}\" and @sourceNodeEntity=\"Issue\" and @sinkNodeEntity=\"Component\" and @associationType=\"IssueComponent\"]"
      assocs = JiraMigration.get_list_from_tag(path)

      categories = []
      assocs.each do |assoc|
        category = JiraComponent::MAP[assoc["sinkNodeId"]]
        categories.push(category)
      end
      categories.last
    end

  	def get_change_groups_of_issue(issueId)
  	  path = "/*/ChangeGroup[@issue=\"#{issueId}\"]/@id"
        groupIdAtts = $doc.xpath(path)
        groupIds = []
        groupIdAtts.each do |item|
          groupIds.push(item.content)
        end
  	  return groupIds
  	end  

  	def get_sprint_changes_of_specific_group(groupId)
  	  path = "/*/ChangeItem[@group=\"#{groupId}\" and @fieldtype=\"custom\" and @field=\"Sprint\"]/@newstring"
  	  sprintAttributes = $doc.xpath(path)
        sprints = []
  	  latestSprint = ""
        sprintAttributes.each do |item|		
  	    if (item.content.length != 0)
  		    latestSprint = item.content
  		  end  
      end
  	  return latestSprint 
  	end

  	def get_previous_sprints
      groupIds = get_change_groups_of_issue(self.jira_id)
      sprints = []
      selected = ""
      currentSprint = ""
      groupIds.each do |item|
        if (item != nil and item.to_s != '')
          currentSprint = get_sprint_changes_of_specific_group(item)
          if (currentSprint.length !=0)
            selected = currentSprint
          end
          sprints.push(currentSprint)
        end
      end
  	  #puts("This is the jira id: #{self.jira_id} and this is the selected sprint: #{selected} out of: #{sprints}")	  
  	  return selected
    end

    def red_subject
      self.jira_summary
    end
	
    # TODO: Reactivate this commented section, but it needs to be faster.
    def red_description
# 	  sprints = get_previous_sprints
# 	  if (sprints.to_s == '')
# 	    dsc = "#{self.jira_marker}\n%s" % @jira_description
# 	  else
# 	    dsc = "#{self.jira_marker}\n Sprints: #{get_previous_sprints}\n\n%s" % @jira_description 
#       end	
#       return dsc	  
      dsc = self.jira_marker + "\n"
      if @jira_description
        dsc += @jira_description
      else
        dsc += self.red_subject
      end
      return dsc
    end

    def red_priority
      name = $MIGRATED_ISSUE_PRIORITIES_BY_ID[self.jira_priority]
      return $MIGRATED_ISSUE_PRIORITIES[name]
    end

    def red_created_on
      Time.parse(self.jira_created)
    end

    def red_updated_on
      Time.parse(self.jira_updated)
    end

    def red_estimated_hours
      self.jira_timeestimate.to_s.empty? ? 0 : self.jira_timeestimate.to_f / 3600
    end

    # def red_start_date
    #   Time.parse(self.jira_created)
    # end

    def red_due_date
      Time.parse(self.jira_resolutiondate) if self.jira_resolutiondate
    end

    def red_status
      name = $MIGRATED_ISSUE_STATUS_BY_ID[self.jira_status]
      return $MIGRATED_ISSUE_STATUS[name]
    end

    def red_tracker
      type_name = $MIGRATED_ISSUE_TYPES_BY_ID[self.jira_type]
      return $MIGRATED_ISSUE_TYPES[type_name]
    end

    def red_author
      JiraMigration.find_user_by_jira_name(self.jira_reporter)
    end

    def red_assigned_to
      if self.jira_assignee
        JiraMigration.find_user_by_jira_name(self.jira_assignee)
      else
        nil
      end
    end

    def before_save(new_record)
      project = JiraProject::MAP[self.jira_project]
      assignee = User.find_by_login(self.jira_assignee) unless self.jira_assignee.nil?
      if !assignee.nil? && !assignee.member_of?(project)
        Member.create(:user => assignee, :project => project, :roles => [ROLE_MAPPING['developer']])
        project.reload
        assignee.reload
      end
    end

    def post_migrate(new_record, is_new)
      if is_new
        # Migrate Key as Custom Field Value
        custom_field = IssueCustomField.find_by_name('Key')
        v = CustomValue.find_by(
          :custom_field_id => custom_field.id,
          :customized_type => 'Issue',
          :customized_id   => new_record.id,
        )
        v.value = self.jira_key
        v.save
        # Migrate environment as Custom Field Value
        unless self.jira_environment.nil? || self.jira_environment.empty?
          custom_field = IssueCustomField.find_by_name('Environment')
          v = CustomValue.find_by(
            :custom_field_id => custom_field.id,
            :customized_type => 'Issue',
            :customized_id   => new_record.id,
          )
          v.value = self.jira_environment
          v.save
        end
      end
      new_record.update_column :updated_on, Time.parse(self.jira_updated)
      new_record.update_column :created_on, Time.parse(self.jira_created)
      new_record.reload
    end
  end

  ##################################
  # Specific class for JIRA comments (= journal in Redmine)
  class JiraComment < BaseJira
    DEST_MODEL = Journal
    MAP = {}

    def initialize(node)
      super(node)
      # get a body from a comment
      # comment can have the comment body as an attribute or as a child tag
      @jira_body = @tag["body"] || @tag.at("body").text
      #@jira_body = node['body']
    end

    def self.parse(xpath = '/*/Action[@type="comment"]')
      objs = super(xpath)
      # Remove comment if related issue is not in the scope
      objs.delete_if{|obj| $MAP_JIRA_ISSUE_ID_TO_KEY[obj.jira_issue].nil? }
      puts "Objects size = #{objs.size}"
      return objs
    end

    def jira_marker
      return "FROM JIRA: #{self.jira_id}"
    end

    def retrieve
      Journal.where(notes: "LIKE '#{self.jira_marker}%'").first()
    end

    # here is the tranformation of Jira attributes in Redmine attribues
    def red_notes
      # You can have the marker in the notes, if you want. Else only the body will be migrated
      #self.jira_marker + "\n" + @jira_body
      @jira_body
    end

    def red_created_on
      DateTime.parse(self.jira_created)
    end

    def red_user
      # retrieving the Rails object
      JiraMigration.find_user_by_jira_name(self.jira_author)
    end

    def red_journalized
      # retrieving the Rails object
      JiraIssue::MAP[self.jira_issue]
    end

    def post_migrate(new_record, is_new)
      new_record.update_column :created_on, Time.parse(self.jira_created)
      new_record.reload
    end
  end

  #####################################
  # Specific class for JIRA attachments
  class JiraAttachment < BaseJira
    DEST_MODEL = Attachment
    MAP = {}

    def self.parse(xpath = '/*/FileAttachment')
      objs = super(xpath)
      # Remove attachment if related issue is not in the scope
      objs.delete_if{|obj| $MAP_JIRA_ISSUE_ID_TO_KEY[obj.jira_issue].nil? }
      puts "Objects size = #{objs.size}"
      return objs
    end

    def retrieve
      nil
    end

    def before_save(new_record)
      new_record.container = self.red_container
      #pp(new_record)

      # JIRA stores attachments as follows:
      # <PROJECTKEY>/<PROJECT-ID/<ISSUE-KEY>/<ATTACHMENT_ID>_filename.ext
      #
      # We have to recreate this path in order to copy the file
      issue_key = $MAP_JIRA_ISSUE_ID_TO_KEY[self.jira_issue]
      project_key = issue_key.gsub(/-\d+$/, '')
      project_id = $MAP_JIRA_PROJECT_ID_TO_KEY.invert[project_key]
      jira_attachment_file = File.join(JIRA_ATTACHMENTS_DIR,
                                       project_key,
                                       #project_id,
                                       issue_key,
                                       "#{self.jira_id}_#{self.jira_filename}"
                                       )
      printf("%-16s | %-.64s | ", issue_key, jira_attachment_file)
      if File.exists? jira_attachment_file
      	file_size = File.size(jira_attachment_file)
      	if file_size < Setting.attachment_max_size.to_i * 1024
          new_record.file = File.open(jira_attachment_file)
          printf("%10s | %16s bytes\n", 'processing', file_size.to_s)
        else
          printf("%24s | %16s bytes\n", 'skipping - too big', file_size.to_s)
        end
        #redmine_attachment_file = File.join(Attachment.storage_path, new_record.disk_filename)

        # puts "Copying attachment [#{jira_attachment_file}] to [#{redmine_attachment_file}]"
        #FileUtils.cp jira_attachment_file, redmine_attachment_file
      else
        printf("%24s | %16s\n", 'skipping - not found', '-')
      end
    end

    # here is the tranformation of Jira attributes in Redmine attribues
    #<FileAttachment id="10084" issue="10255" mimetype="image/jpeg" filename="Landing_Template.jpg"
    #                created="2011-05-05 15:54:59.411" filesize="236515" author="emiliano"/>
    def red_filename
      self.jira_filename.gsub(/[^\w\.\-]/,'_')  # stole from Redmine: app/model/attachment (methods sanitize_filenanme)
    end

    # def red_disk_filename
    #   Attachment.disk_filename(self.jira_issue+self.jira_filename)
    # end

    def red_content_type
      self.jira_mimetype.to_s.chomp
    end

    # def red_filesize
    #   self.jira_filesize
    # end

    def red_created_on
      DateTime.parse(self.jira_created)
    end

    def red_author
      JiraMigration.find_user_by_jira_name(self.jira_author)
    end

    def red_container
      JiraIssue::MAP[self.jira_issue]
    end

    def post_migrate(new_record, is_new)
      new_record.update_column :created_on, Time.parse(self.jira_created)
      new_record.reload
    end
  end


  ISSUELINK_TYPE_MARKER = IssueRelation::TYPE_RELATES
  DEFAULT_ISSUELINK_TYPE_MAP = {
      # Default map from Jira (key) to Redmine (value)
      "Duplicate" => IssueRelation::TYPE_DUPLICATES,              # inward="is duplicated by" outward="duplicates"
      "Relates" => IssueRelation::TYPE_RELATES,  # inward="relates to" outward="relates to"
      "Blocked" => IssueRelation::TYPE_BLOCKS,  # inward="blocked by" outward="blocks"
      "Dependent" => IssueRelation::TYPE_FOLLOWS,            # inward="is depended on by" outward="depends on"
      "Epic-Story Link" => "Epic-Story",
      "jira_subtask_link" => "Subtask"
  }


  ISSUE_TYPE_MARKER = "(choose a Redmine Tracker)"
  DEFAULT_ISSUE_TYPE_MAP = {
      # Default map from Jira (key) to Redmine (value)
      # the comments on right side are Jira definitions - http://confluence.atlassian.com/display/JIRA/What+is+an+Issue#
      "Bug" => "Bug",              # A problem which impairs or prevents the functions of the product.
      "Improvement" => "Feature",  # An enhancement to an existing feature.
      "New Feature" => "Feature",  # A new feature of the product.
      "Epic" => "Feature",            # A task that needs to be done.
      "Story" => "Feature",            # A task that needs to be done.
      "Task" => "Feature",            # A task that needs to be done.
      "Technical task" => "Feature",            # A task that needs to be done.
      "QA task" => "Feature",            # A task that needs to be done.
      "Custom Issue" => "Support" # A custom issue type, as defined by your organisation if required.
  }


  ISSUE_STATUS_MARKER = "(choose a Redmine Issue Status)"
  DEFAULT_ISSUE_STATUS_MAP = {
      # Default map from Jira (key) to Redmine (value)
      # the comments on right side are Jira definitions - http://confluence.atlassian.com/display/JIRA/What+is+an+Issue#
      "Open" => "New",                # This issue is in the initial 'Open' state, ready for the assignee to start work on it.
      "In Progress" => "In Progress", # This issue is being actively worked on at the moment by the assignee.
      "Resolved" => "Resolved",       # A Resolution has been identified or implemented, and this issue is awaiting verification by the reporter. From here, issues are either 'Reopened' or are 'Closed'.
      "Reopened" => "New",       # This issue was once 'Resolved' or 'Closed', but is now being re-examined. (For example, an issue with a Resolution of 'Cannot Reproduce' is Reopened when more information becomes available and the issue becomes reproducible). From here, issues are either marked In Progress, Resolved or Closed.
      "Closed" => "Closed",           # This issue is complete. ## Be careful to choose one which a "issue closed" attribute marked :-)
      "In Test" => "In Test",
      "Verified" => "Verified"
  }


  ISSUE_PRIORITY_MARKER = "(choose a Redmine Enumeration Issue Priority)"
  DEFAULT_ISSUE_PRIORITY_MAP = {
      # Default map from Jira (key) to Redmine (value)
      # the comments on right side are Jira definitions - http://confluence.atlassian.com/display/JIRA/What+is+an+Issue#
      "Blocker" => "Blocker", # Highest priority. Indicates that this issue takes precedence over all others.
      "Critical" => "Urgent",   # Indicates that this issue is causing a problem and requires urgent attention.
      "Major" => "High",        # Indicates that this issue has a significant impact.
      "Minor" => "Normal",      # Indicates that this issue has a relatively minor impact.
      "Trivial" => "Low",       # Lowest priority.
  }


  CUSTOM_FIELD_TYPE_MARKER = "(choose a Redmine Enumeration Custom Field type)"
  DEFAULT_CUSTOM_FIELD_TYPE_MAP = {
    # Default map from Jira (key) to Redmine (value)
      #''                                                                => 'Boolean', # Checkbox
      'com.pyxis.greenhopper.jira:greenhopper-ranking'                   => 'float',   # Numeric
      'com.atlassian.jira.plugin.system.customfieldtypes:float'          => 'float',   # Float
      'com.atlassian.jira.plugin.system.customfieldtypes:textfield'      => 'text',    # String
      'com.atlassian.jira.plugin.system.customfieldtypes:url'            => 'link',    # URL
      'com.atlassian.jira.plugin.system.customfieldtypes:userpicker'     => 'user',    # Single user
      'com.atlassian.jira.plugin.system.customfieldtypes:textarea'       => 'text',    # Long text
      'com.atlassian.jira.plugin.system.customfieldtypes:select'         => 'list',    # Enumeration
      'com.atlassian.jira.plugin.system.customfieldtypes:multiuserpicker'=> 'list',    # User list
      #''                                                                => 'Date',    # Date
      #''                                                                => 'Version', # Version
  }

  # Xml file holder
  $doc = nil

  # A dummy Redmine user to use in place of JIRA users who have been deleted.
  # This user is lazily migrated only if needed.
  $GHOST_USER = nil

  # Mapping between Jira Issue Type and Jira Issue Type Id - key = Id, value = Type
  $MIGRATED_ISSUE_TYPES_BY_ID = {}
  # Mapping between Jira Issue Status and Jira Issue Status Id - key = Id, value = Status
  $MIGRATED_ISSUE_STATUS_BY_ID = {}
  # Mapping between Jira Issue Priority and Jira Issue Priority Id - key = Id, value = Priority
  $MIGRATED_ISSUE_PRIORITIES_BY_ID = {}


  # Mapping between Jira Issue Type and Redmine Issue Type - key = Jira, value = Redmine
  $MIGRATED_ISSUE_TYPES = {}
  # Mapping between Jira Issue Status and Redmine Issue Status - key = Jira, value = Redmine
  $MIGRATED_ISSUE_STATUS = {}
  # Mapping between Jira Issue Priorities and Redmine Issue Priorities - key = Jira, value = Redmine
  $MIGRATED_ISSUE_PRIORITIES = {}

  # Migrated Users by Name.
  $MIGRATED_USERS_BY_NAME = {}

  # Mapping of Jira id to Jira key to filter many objects and speed up attachment processing
  $MAP_JIRA_PROJECT_ID_TO_KEY = {}
  $MAP_JIRA_ISSUE_ID_TO_KEY = {}

  ##########################
  # gets all mapping options
  def self.get_all_options()
    # return all options 
    # Issue Type, Issue Status, Issue Priority
    ret = {}
    ret["types"] = self.get_jira_issue_types()
    ret["status"] = self.get_jira_statuses()
    ret["priorities"] = self.get_jira_priorities()
    ret["custom_field_types"] = self.get_jira_custom_field_types()

    return ret
  end

  ###############################################
  # Return the limit size of an Redmine attribute
  def self.limit_for(klass, attribute)
    klass.columns_hash[attribute.to_s].limit
  end

  #####################
  def self.encode(text)
  	if text.nil?
  	  text = ''
  	end
    text.to_s.force_encoding('UTF-8').encode('UTF-8')
  end

  ##################################
  # Get or create Ghost (Dummy) user
  # which will be used for jira issues if no corresponding user found
  def self.use_ghost_user
    ghost = User.find_by_login('deleted-user')
    if ghost.nil?
      puts "Creating ghost user to represent deleted JIRA users. Login name = deleted-user"
      ghost = User.new({  :firstname => 'Deleted',
                          :lastname => 'User',
                          :mail => 'deleted.user@example.com',
                          :password => 'deleteduser123' })
      ghost.login = 'deleted-user'
      ghost.lock # disable the user
      ghost.save!
      ghost.reload
    end
    $GHOST_USER = ghost
    ghost
  end

  ##########################################
  def self.find_user_by_jira_name(jira_name)
    #printf("Searching for user %s. ", jira_name) 
    user = $MIGRATED_USERS_BY_NAME[jira_name]
    #printf("Found %s\n", user)
    if user.nil?
      # User has not been migrated. Probably a user who has been deleted from JIRA.
      # Select or create the ghost user and use him instead.
      user = use_ghost_user
    end
    user
  end

  #######################################
  def self.get_list_from_tag(xpath_query)
    # Get a tag node and get all attributes as a hash
    ret = []
    # $doc.elements.each(xpath_query) {|node| ret.push(node.attributes.rehash)}
    $doc.xpath(xpath_query).each {|node|
      nm = node.attr("name")
      ret.push(Hash[node.attributes.map { |k,v| [k,v.content]}])}
      #ret.push(node.attributes.rehash)}
    return ret
  end

  #################################
  def self.migrate_fixed_versions()
    path = "/*/NodeAssociation[@sourceNodeEntity=\"Issue\" and @sinkNodeEntity=\"Version\" and @associationType=\"IssueFixVersion\"]"
    associations = JiraMigration.get_list_from_tag(path)

    printf("%12s | %12s | %-24s | %-12s\n",
      'issue_jid',
      'version_jid',
      'version_name',
      'issue_rid')
    associations.each do |assoc|
      # Only process relevant assoc (should be nil if project is ignored)
      version = JiraVersion::MAP[assoc['sinkNodeId']]
      if !version.nil?
    	issue = JiraIssue::MAP[assoc['sourceNodeId']]
      	if !issue.nil?
          printf("%12i | %12i | %-24s | %-12s\n",
            assoc['sinkNodeId'],
            assoc['sourceNodeId'],
            version['name'],
            issue.id
          )
          issue.update_column(:fixed_version_id, version.id)
          issue.reload
        end
      end
    end
  end

  #############################
  def self.migrate_membership()
    memberships = self.get_list_from_tag('/*/Membership[@membershipType="GROUP_USER"]')

    memberships.each do |m|
      user = User.find_by_login(m['lowerChildName'])
      if user.nil? or user == $GHOST_USER
        users = self.get_list_from_tag("/*/User[@lowerUserName=\"%s\"]" % m['lowerChildName'])
        if !users.nil? and !users.empty?
          user = User.find_by_mail(users[0]['emailAddress'])
        end
      end
      group = Group.find_by_lastname(m['lowerParentName'])
      if !user.nil? and !group.nil?
        if !group.users.exists?(user.id)
         group.users << user
        end
      end
    end

    memberships = self.get_list_from_tag('/*/OSMembership')

    memberships.each do |m|
      user = User.find_by_login(m['userName'])
      if user.nil? or user == $GHOST_USER
        users = self.get_list_from_tag("/*/OSUser[@login=\"%s\"]" % m['userName'])
        if !users.nil? and !users.empty?
          user = User.find_by_mail(users[0]['emailAddress'])
        end
      end
      group = Group.find_by_lastname(m['groupName'])
      if !user.nil? and !group.nil?
        if !group.users.exists?(user.id)
         group.users << user
        end
      end
    end
  end

  ##############################
  def self.migrate_issue_links()
    # Issue Link Types
    issue_link_types = self.get_list_from_tag('/*/IssueLinkType')
    # migrated_issue_link_types = {"jira issuelink type" => "redmine link type"}
    migrated_issue_link_types = {}
    issue_link_types.each do |linktype|
      migrated_issue_link_types[linktype['id']] = DEFAULT_ISSUELINK_TYPE_MAP.fetch(linktype['linkname'], ISSUELINK_TYPE_MARKER)
    end
    #pp(migrated_issue_link_types)

    # Set Issue Links
    issue_links = self.get_list_from_tag('/*/IssueLink')
    puts("Collected #{issue_links.length} issue links")
    issue_links.each do |link|
      linktype = migrated_issue_link_types[link['linktype']]
      issue_from = JiraIssue::MAP[link['source']]
      issue_to = JiraIssue::MAP[link['destination']]
      # Only process relevant links
      if !issue_from.nil? && !issue_to.nil?
        if linktype.downcase == 'subtask' || linktype.downcase == 'epic-story'
          #pp "Set Parent #{issue_from.id} to:", issue_to
          to_updated_on = issue_to.updated_on
          from_updated_on = issue_from.updated_on
          issue_to.update_attribute(:parent_issue_id, issue_from.id)
          issue_to.reload
          issue_to.update_column :updated_on, to_updated_on
          issue_from.update_column :updated_on, from_updated_on
          issue_to.reload
          issue_from.reload
        else
          r = IssueRelation.new(:relation_type => linktype, :issue_from => issue_from, :issue_to => issue_to)
		  puts "setting relation between: #{issue_from.id} to: #{issue_to.id}"
		  begin
		    r.save!
		    r.reload
		  rescue Exception => e
		    puts "FAILED setting #{linktype} relation from: #{issue_from.id} to: #{issue_to.id} because of #{e.message}"
		  end
		  puts "After saving the relation"
		end
      end
    end
  end

  ###########################
  def self.migrate_worktime()
    # Set Issue Links
    worklogs = self.get_list_from_tag('/*/Worklog')
    puts("Collected #{worklogs.length} worklogs")
    worklogs.each do |log|
      issue = JiraIssue::MAP[log['issue']]
      # Only process relevant worklogs
      if !issue.nil?
        user = JiraMigration.find_user_by_jira_name(log['author'])
        TimeEntry.create!(:user => user, :issue_id => issue.id, :project_id => issue.project.id,
                          :hours => (log['timeworked'].to_s.empty? ? 0 : log['timeworked'].to_f / 3600),
                          :comments => log['body'].to_s.truncate(250, separator: ' '),
                          :spent_on => Time.parse(log['startdate']),
                          :created_on => Time.parse(log['created']),
                          :activity_id => TimeEntryActivity.find_by_name('Development').id)
      end
    end
  end

  ###############################
  def self.get_jira_issue_types()
    # Issue Type
    issue_types = self.get_list_from_tag('/*/IssueType') 
    # migrated_issue_types = {"jira_type" => "redmine tracker"}
    migrated_issue_types = {}
    issue_types.each do |issue|
      migrated_issue_types[issue["name"]] = DEFAULT_ISSUE_TYPE_MAP.fetch(issue["name"], ISSUE_TYPE_MARKER)
      $MIGRATED_ISSUE_TYPES_BY_ID[issue["id"]] = issue["name"]
    end
    return migrated_issue_types
  end

  ############################
  def self.get_jira_statuses()
    # Issue Status
    issue_status = self.get_list_from_tag('/*/Status')
    # migrated_issue_status = {"jira_status" => "redmine status"}
    migrated_issue_status = {}
    issue_status.each do |issue|
      migrated_issue_status[issue["name"]] = DEFAULT_ISSUE_STATUS_MAP.fetch(issue["name"], ISSUE_STATUS_MARKER)
      $MIGRATED_ISSUE_STATUS_BY_ID[issue["id"]] = issue["name"]
    end
    return migrated_issue_status
  end

  ##############################
  def self.get_jira_priorities()
    # Issue Priority
    issue_priority = self.get_list_from_tag('/*/Priority')
    # migrated_issue_priority = {"jira_priortiy" => "redmine priority"}
    migrated_issue_priority = {}
    issue_priority.each do |issue|
      migrated_issue_priority[issue["name"]] = DEFAULT_ISSUE_PRIORITY_MAP.fetch(issue["name"], ISSUE_PRIORITY_MARKER)
      $MIGRATED_ISSUE_PRIORITIES_BY_ID[issue["id"]] = issue["name"]
    end
    return migrated_issue_priority
  end

  ##############################
  def self.get_jira_custom_field_types()
    # Custom Field types
    custom_fields = self.get_list_from_tag('/*/CustomField')
    # migrated_custom_fields_type = {"jira_type" => "redmine type"}
    migrated_custom_fields_type = {}
    custom_fields.each do |field|
      if migrated_custom_fields_type[field["customfieldtypekey"]].nil?
        migrated_custom_fields_type[field["customfieldtypekey"]] = DEFAULT_CUSTOM_FIELD_TYPE_MAP.fetch(field["customfieldtypekey"], CUSTOM_FIELD_TYPE_MARKER)
      end
    end
    return migrated_custom_fields_type
  end

  ##########################################################
  # Parse jira xml for users and return an array of JiraUser
  # TODO: Migrate this method into JiraUser.parse
  def self.parse_jira_users()
    users = []

    # For users in Redmine we need:
    # First Name, Last Name, E-mail, Password
    #<User id="110" directoryId="1" userName="userName" lowerUserName="username" active="1" createdDate="2013-08-14 13:07:57.734" updatedDate="2013-09-29 21:52:19.776" firstName="firstName" lowerFirstName="firstname" lastName="lastName" lowerLastName="lastname" displayName="User Name" lowerDisplayName="user name" emailAddress="user@mail.org" lowerEmailAddress="user@mail.org" credential="" externalId=""/>

    # $doc.elements.each('/*/User') do |node|
    $doc.xpath('/*/User').each do |node|
      if(node['emailAddress'] =~ /\A([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})\z/i)
        if !node['firstName'].to_s.empty? and !node['lastName'].to_s.empty? 
		  user = JiraUser.new(node)
		  user.jira_emailAddress = node["lowerEmailAddress"]
		  user.jira_name = node["lowerUserName"]
		  user.jira_active = node['active']
		  #puts "Found JIRA user: #{user.jira_name}"
		  users.push(user)
        end
      end
    end

    # Process alternative tag if any
    entries = $doc.xpath("/*/OSPropertyEntry[@entityName=\"OSUser\"]") # Collect PropertyEntry nodes from XML
    strings = $doc.xpath("/*/OSPropertyString") unless entries.empty?  # Collect PropertyString nodes from XML if relevant
    unless strings.empty?# 
      puts "Found OSProperties: trying to collect OSUsers"
      $doc.xpath('/*/OSUser').each do |node|                           # Collect OSUser nodes from XML if relevant
        props = {}
        user = JiraUser.new(node)
        #puts "Looking info for user = #{user.jira_id}"
        entries.select{ |e| e['entityId'] == user.jira_id }.each do |entry|
          #puts ("Key id = #{entry['id']} / value = #{entry['propertyKey']}")
          string = strings.select{ |i| i['id'] == entry['id'] }.last()
          props[entry['propertyKey']] = string['value'] unless string.nil?
        end
        #pp user
        #pp props
        unless props['email'].nil? || props['email'] !~ /\A([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})\z/i
          user.jira_emailAddress = props['email']
          if props['fullName'].nil?
            user.jira_firstName = 'unknown'
            user.jira_lastName = 'unknown'
          else
            fullName = props['fullName'].split(' ', 2)
            #pp fullName
            user.jira_firstName = fullName[0]
            if fullName.size > 1
              user.jira_lastName = fullName[1]
            else
              user.jira_lastName = 'unknown'
            end
          end
          #pp user
          #puts "Found JIRA user: #{user.jira_name} | #{user.jira_emailAddress} | #{user.jira_firstName} | #{user.jira_lastName}"
          users.push(user)
        end
      end
    end
    return users
  end

  #######################################################################
  # Migrate an array of objects while displaying some targeted attributes
  # Ex:
  #   migrate(users, {'jira_key' => -10, 'jira_id' => 10, 'jira_assignee' => -10})
  #
  # Will produce something like this:
  # jira_key   |    jira_id | status   |           id
  # PRJ-007    |      19756 | exists   |          156
  # PRJ-008    |      19757 | created  |          478
  def self.migrate(objs, attrs, vsep = " \\ ", hsep = '\\')
    # Compute adapted size for horizontal separator
    sep = 20 + vsep.size
    attrs.each do |name,format|
      sep += format.abs
      sep += vsep.size
    end

    # Print header
    1.upto(sep).each { putc(hsep) }
    puts
    attrs.each do |name,format|
      printf("%#{format.to_s}.#{format.to_s.sub('-', '')}s#{vsep}", name)
    end
    printf("%-8s#{vsep}%12s\n", 'status', 'red_id')
    1.upto(sep).each { putc(hsep) }
    puts

    # Prepare counter
    created = 0

    # Print attributes
    objs.each do |obj|
      attrs.each do |name,format|
        att = '-'
        begin
          # Try to call the getter method first
          att = obj.send(name)
        rescue NoMethodError => e
          # Fallback on the attribute
          att = obj[name] unless obj[name].nil?
        end
        printf("%#{format.to_s}.#{format.to_s.sub('-', '')}s#{vsep}", att)
      end
      begin
        obj.migrate
      rescue NoMethodError => e
        printf("%-8s#{vsep}%12s\n", 'NoMethod', '-')
        raise
        abort
      end

      # Print status
      if obj.is_new
        printf("%-8s#{vsep}", 'created')
        created += 1
      else
        printf("%-8s#{vsep}", 'exists')
      end
      printf("%12s\n", obj.new_record.id.to_s)
    end
    1.upto(sep).each { putc(hsep) }
    puts
    return created
  end
end

############################
namespace :jira_migration do
  task :load_xml => :environment do

    file = File.new(JiraMigration::ENTITIES_FILE, 'r:utf-8')
    $doc = Nokogiri::XML(file, nil, 'utf-8')

    $MIGRATED_USERS_BY_NAME = Hash[User.all.map{|u|[u.login, u]}] #{} # Maps the Jira username to the Redmine Rails User object
  end

  ##########################################################################
  desc "Generates the configuration for the map things from Jira to Redmine"
  task :generate_conf => [:environment, :load_xml] do
    conf_file = JiraMigration::CONF_FILE
    conf_exists = File.exists?(conf_file)
    if conf_exists
      puts "You already have a conf file"
      print "You want overwrite it ? [y/N] "
      overwrite = STDIN.gets.match(/^y$/i)
    end

    if !conf_exists or overwrite
      # Let's give the user all options to fill out
      options = JiraMigration.get_all_options()

      File.open(conf_file, "w"){ |f| f.write(options.to_yaml) }

      puts "This migration script needs the migration table to continue "
      puts "Please... fill the map table on the file: '#{conf_file}' and run again the script"
      puts "To start the options again, just remove the file '#{conf_file} and run again the script"
      exit(0)
    end
  end

  #######################################
  desc "Gets the configuration from YAML"
  task :pre_conf => [:environment, :load_xml] do

    conf_file = JiraMigration::CONF_FILE
    conf_exists = File.exists?(conf_file)

    if !conf_exists
      Rake::Task['jira_migration:generate_conf'].invoke
    end
    $confs = YAML.load_file(conf_file)
  end

  ####################################################
  desc "Migrates Jira Issue Types to Redmine Trackers"
  task :migrate_issue_types => [:environment, :pre_conf] do

    JiraMigration.get_jira_issue_types()
    types = $confs["types"]
    types.each do |key, value|
      t = Tracker.find_by_name(value)
      if t.nil?
        t = Tracker.new(name: value)
      end
      printf("%s => %s\n", key, value)
      t.save!
      t.reload
      $MIGRATED_ISSUE_TYPES[key] = t
    end
    puts "Migrated issue types"
  end

  ###################################################
  desc "Migrates Jira Issue Status to Redmine Status"
  task :migrate_issue_status => [:environment, :pre_conf] do
    JiraMigration.get_jira_statuses()
    status = $confs["status"]
    status.each do |key, value|
      s = IssueStatus.find_by_name(value)
      if s.nil?
        s = IssueStatus.new(name: value)
      end
      printf("%s => %s\n", key, value)
      s.save!
      s.reload
      $MIGRATED_ISSUE_STATUS[key] = s
    end
    puts "Migrated issue status"
  end

  ###########################################################
  desc "Migrates Jira Issue Priorities to Redmine Priorities"
  task :migrate_issue_priorities => [:environment, :pre_conf] do
    JiraMigration.get_jira_priorities()
    priorities = $confs["priorities"]

    priorities.each do |key, value|
      p = IssuePriority.find_by_name(value)
      if p.nil?
        p = IssuePriority.new(name: value)
      end
      printf("%s => %s\n", key, value)
      p.save!
      p.reload
      $MIGRATED_ISSUE_PRIORITIES[key] = p
    end
    puts "Migrated issue priorities"
  end

  #######################
  desc "Migrates custom fields"
  task :migrate_custom_fields => [:environment, :pre_conf] do
    fields = JiraMigration::JiraCustomField.parse
    attrf = JiraMigration::JiraCustomField::ATTRF
    created = JiraMigration.migrate(fields, attrf)
    puts "Migrated custom fields (#{created}/#{fields.size})"
  end

  ###########################################
  desc "Migrates Jira Users to Redmine Users"
  task :migrate_users => [:environment, :pre_conf] do
    # TODO: Rework to use JiraUser::parse
    users = JiraMigration.parse_jira_users()
    attrf = JiraMigration::JiraUser::ATTRF
    created = JiraMigration.migrate(users, attrf)
    puts "Migrated users (#{created}/#{users.size})"
  end

  ###########################################
  desc "Migrates Jira Group to Redmine Group"
  task :migrate_groups => [:environment, :pre_conf] do
    groups = JiraMigration::JiraGroup.parse
    attrf = JiraMigration::JiraGroup::ATTRF
    created = JiraMigration.migrate(groups, attrf)
    puts "Migrated groups (#{created}/#{groups.size})"

    # TODO: Implement this is JiraGroup::post_migrate
    JiraMigration.migrate_membership
    puts "Migrated Membership"
  end

  #################################################
  desc "Migrates Jira Projects to Redmine Projects"
  task :migrate_projects => :environment do
    projects = JiraMigration::JiraProject.parse
    attrf = JiraMigration::JiraProject::ATTRF
    created = JiraMigration.migrate(projects, attrf)
    puts "Migrated projects (#{created}/#{projects.size})"
  end

  #################################################
  desc "Migrates Jira Versions to Redmine Versions"
  task :migrate_versions => :environment do
    versions = JiraMigration::JiraVersion.parse
    versions.reject!{|version|version.red_project.nil?}
    attrf = JiraMigration::JiraVersion::ATTRF
    created = JiraMigration.migrate(versions, attrf)
    puts "Migrated versions (#{created}/#{versions.size})"
  end

  ###########################################################
  desc "Migrates Jira Components to Redmine Issue Categories"
  task :migrate_components => :environment do
    categories = JiraMigration::JiraComponent.parse
    categories.reject!{|category|category.red_project.nil?}
    attrf = JiraMigration::JiraComponent::ATTRF
    created = JiraMigration.migrate(categories, attrf)
    puts "Migrated categories (#{created}/#{categories.size})"
  end

  #############################################
  desc "Migrates Jira Issues to Redmine Issues"
  task :migrate_issues => :environment do
    issues = JiraMigration::JiraIssue.parse
    issues.reject!{|issue|issue.red_project.nil?}
    attrf = JiraMigration::JiraIssue::ATTRF
    created = JiraMigration.migrate(issues, attrf)
    puts "Migrated issues (#{created}/#{issues.size})"

    # TODO: Implement this is JiraIssue::post_migrate, if possible
    JiraMigration.migrate_fixed_versions
    JiraMigration.migrate_issue_links
    JiraMigration.migrate_worktime
  end

  #######################################################################
  desc "Migrates Jira Issues Comments to Redmine Issues Journals (Notes)"
  task :migrate_comments => :environment do
    comments = JiraMigration::JiraComment.parse
    comments.reject!{|comment|comment.red_journalized.nil?}
    comments.each do |c|
      #pp(c)
      c.migrate
    end
  end

  ##############################################################
  desc "Migrates Jira Issues Attachments to Redmine Attachments"
  task :migrate_attachments => :environment do
    attachs = JiraMigration::JiraAttachment.parse
    attachs.reject!{|attach|attach.red_container.nil?}
    attachs.each do |a|
      #pp(c)
      a.migrate
    end
  end

  ##################################### Tests ##########################################
  desc "Just pretty print Jira Projects on screen"
  task :test_parse_projects => :environment do
    projects = JiraMigration::JiraProject.parse
    projects.each {|p| pp(p.run_all_redmine_fields) } if $PP
  end

  desc "Just pretty print Jira Users on screen"
  task :test_parse_users => :environment do
    # TODO: Rework to use JiraUser::parse
    users = JiraMigration.parse_jira_users()
    users.each {|u| pp( u.run_all_redmine_fields) } if $PP
  end

  desc "Just pretty print Jira Groups on screen"
  task :test_parse_groups => :environment do
    groups = JiraMigration::JiraGroup.parse
    groups.each {|g| pp( g.run_all_redmine_fields) } if $PP
  end

  desc "Just pretty print Jira Versions on screen"
  task :test_parse_versions => :environment do
    versions = JiraMigration::JiraVersion.parse
    versions.each {|c| pp( c.run_all_redmine_fields) } if $PP
  end

  desc "Just pretty print Jira Components on screen"
  task :test_parse_components => :environment do
    categories = JiraMigration::JiraComponent.parse
    categories.each {|c| pp( c.run_all_redmine_fields) } if $PP
  end

  desc "Just pretty print Jira Custom Fields on screen"
  task :test_parse_custom_fields => :environment do
    fields = JiraMigration::JiraCustomField.parse
    fields.each {|c| pp( c.run_all_redmine_fields) } if $PP
  end

  desc "Just pretty print Jira Issues on screen"
  task :test_parse_issues => :environment do
    issues = JiraMigration::JiraIssue.parse
    issues.each {|i| pp( i.run_all_redmine_fields) } if $PP
  end

  desc "Just pretty print Jira Comments on screen"
  task :test_parse_comments => :environment do
    comments = JiraMigration::JiraComment.parse
    comments.each {|c| pp( c.run_all_redmine_fields) } if $PP
  end

  desc "Just pretty print Jira Attachments on screen"
  task :test_parse_attachments => :environment do
    attachs = JiraMigration::JiraAttachment.parse
    attachs.each {|i| pp( i.run_all_redmine_fields) } if $PP
  end

  ##################################### Running all tests ##########################################
  desc "Tests all parsers!"
  task :test_all_migrations => [:environment, :pre_conf,
    :test_parse_users,
    :test_parse_groups,
    :test_parse_projects,
    :test_parse_versions,
    :test_parse_components,
    :test_parse_custom_fields,
    :test_parse_issues,
    :test_parse_comments,
    :test_parse_attachments
  ] do
    puts "All parsers done! :-)"
  end

  ##################################### Running all tasks ##########################################
  desc "Run all parsers!"
  task :do_all_migrations => [:environment, :pre_conf,
    :migrate_issue_types,
    :migrate_issue_status,
    :migrate_issue_priorities,
    :migrate_users,
    :migrate_groups,
    :migrate_projects,
    :migrate_versions,
    :migrate_components,
    :migrate_custom_fields,
    :migrate_issues,
    :migrate_comments,
    :migrate_attachments
  ] do
    puts "All migrations done! :-)"
  end
end
