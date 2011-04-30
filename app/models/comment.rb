class Comment < ActiveRecord::Base
  include Immortal
  
  extend ActiveSupport::Memoizable
  
  concerned_with :tasks, :finders, :conversions

  belongs_to :user
  belongs_to :project
  belongs_to :target, :polymorphic => true, :counter_cache => true
  belongs_to :assigned, :class_name => 'Person'
  belongs_to :previous_assigned, :class_name => 'Person'

  has_many :notifications, :dependent => :destroy

  def task_comment?
    self.target_type == "Task"
  end
  
  def user
    @user ||= user_id ? User.with_deleted.find_by_id(user_id) : nil
  end
  
  def assigned
    @assigned ||= assigned_id ? Person.with_deleted.find_by_id(assigned_id) : nil
  end
  
  def previous_assigned
    @previous_assigned ||= previous_assigned_id ? Person.with_deleted.find_by_id(previous_assigned_id) : nil
  end

  has_many :uploads
  accepts_nested_attributes_for :uploads, :allow_destroy => true,
    :reject_if => lambda { |upload| upload['asset'].blank? }
  
  has_many :google_docs
  accepts_nested_attributes_for :google_docs, :allow_destroy => true,
    :reject_if => lambda { |google_docs| google_docs['title'].blank? || google_docs['url'].blank? }
  
  attr_accessible :body, :status, :assigned, :hours, :human_hours, :billable,
                  :upload_ids, :uploads_attributes, :due_on, :google_docs_attributes, :private_ids, :is_private

  attr_accessor :is_importing
  attr_accessor :private_ids

  scope :by_user, lambda { |user| { :conditions => {:user_id => user} } }
  scope :latest, :order => 'id DESC'

  # TODO: investigate how we can enable this and not break nested attributes
  # validates_presence_of :target_id, :user_id, :project_id
  
  validate :check_duplicate, :if => lambda { |c| !@is_importing and c.target_id? and not c.hours? }, :on => :create
  validates_presence_of :body, :unless => lambda { |c| c.task_comment? or c.uploads.to_a.any? or c.google_docs.any? }

  validates_presence_of :user

  # was before_create, but must happen before format_attributes
  before_validation   :copy_ownership_from_target, :on => :create, :if => lambda { |c| c.target }
  after_create  :trigger_target_callbacks
  after_destroy :cleanup_activities, :cleanup_conversation

  # must happen after copy_ownership_from_target
  formats_attributes :body

  attr_accessor :activity

  def hours?
    hours and hours > 0
  end

  scope :with_hours, :conditions => 'hours > 0'

  alias_attribute :human_hours, :hours

  # Instead of using the float 'hours' field in a form, we use 'human_hours'
  # and we can take:
  # 7 (hours)
  # 7.5 (hours with decimals)
  # 7h (hours)
  # 30m (minutes => fractions of hours)
  # 2h 30m (hours and minutes => hours with decimals)
  # 2:30 (hours and minutes => hours with decimals)
  def human_hours=(duration)
    self.hours = if duration.blank?
      nil
    elsif duration =~ /(\d+)h[ ]*(\d+)m/i
      # 2h 15m
      $1.to_f + $2.to_f / 60
    elsif duration =~ /(\d+):(\d+)/
      # 2:15
      $1.to_f + $2.to_f / 60.0
    elsif duration =~ /(\d+)m/i
      # 20m
      $1.to_f / 60.0
    elsif duration =~ /(\d+)h/i
      # 3h
      $1.to_f
    else
      # old-style numeric format
      duration.to_f
    end
  end

  def duplicate_of?(another)
    [:body, :assigned_id, :status, :hours].all? { |prop|
      self.send(prop) == another.send(prop)
    }
  end

  def thread_id
    "#{target_type}_#{target_id}"
  end
  
  def references
    refs = { :users => [user_id], :projects => [project_id] }
    refs.merge!({ target_type.tableize.to_sym => [target_id] })
    refs[:people] = []
    refs[:people] << assigned_id if assigned_id
    refs[:people] << previous_assigned_id if previous_assigned_id
    refs
  end
  
  protected

  # don't allow two identical updates in a row
  #
  # FIXME: doesn't work with "simple" conversations because
  # they hijack `target` in a before_save callback
  def check_duplicate
    last_comment = target.comments.by_user(self.user_id).latest.first

    if last_comment and last_comment.duplicate_of? self
      last_uploads = last_comment.uploads.map {|x| x.asset_file_name + '_' + x.asset_file_size.to_s }.sort
      current_uploads = self.uploads.map {|x| x.asset_file_name + '_' + x.asset_file_size.to_s }.sort
      if current_uploads == last_uploads
        errors.add :body, :duplicate
      end
    end
  end

  def copy_ownership_from_target # before_create
    self.user_id ||= target.user_id
    self.project_id ||= target.project_id
    # Private field inherits from target UNLESS it is set and its being changed by the owner
    can_change_private = self.user_id == target.user_id
    if target.respond_to?(:is_private)
      self[:is_private] = target.is_private unless can_change_private && @is_private_set
    end
    true
  end
  
  def is_private=(value)
    self[:is_private] = value
    @is_private_set = true
  end

  def trigger_target_callbacks # after_create
    @activity = project.log_activity(self, 'create') if project_id?
    return if target.nil?

    if target.respond_to?(:add_watchers)
      can_mention_watchers = true
      
      # Allow the owner to change the privacy status
      if target.respond_to?(:is_private)
        can_change_private = self.user_id == target.user_id
        target.is_private = self.is_private if can_change_private
        if target.is_private && can_change_private && @private_ids && @is_private_set
          target.set_private_watchers(@private_ids)
        elsif target.is_private
          target.add_watchers([target.user])
        end
      end
      
      if !target.is_private
        new_watchers = defined?(@mentioned) ? @mentioned.to_a : []
        new_watchers << self.user if self.user
        target.add_watchers new_watchers
      end
    end
    
    if target.respond_to?(:updated_at)
      target.updated_at = self.created_at
    end
    
    target.save(:validate => false)
  end
  
  def cleanup_activities # after_destroy
    Activity.destroy_all :target_type => self.class.name, :target_id => self.id
  end
  
  def cleanup_conversation
    if self.target.class == Conversation
      @conversation = self.target
      @conversation.destroy if @conversation.simple and @conversation.comments.count == 0
    end
  end
end
