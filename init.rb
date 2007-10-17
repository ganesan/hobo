# Monkey patches, ooh ooh
require 'extensions'
require 'rexml'
require 'active_record/has_many_association'
require 'active_record/has_many_through_association'
require 'active_record/table_definition'
require 'action_view_extensions/base'

require 'hobo'
require 'hobo/dryml'

require 'hobo/model'
require 'hobo/field_declaration_dsl'

require 'hobo/dryml/template'
require 'hobo/dryml/taglib'
require 'hobo/dryml/template_environment'
require 'hobo/dryml/template_handler'

require 'hobo/plugins'

require 'extensions/test_case' if RAILS_ENV == "test"

# Rich data types
require "hobo/html_string"
require "hobo/markdown_string"
require "hobo/textile_string"
require "hobo/password_string"
require "hobo/text"
require "hobo/email_address"
require "hobo/enum_string"
require "hobo/percentage"


ActionView::Base.register_template_handler("dryml", Hobo::Dryml::TemplateHandler)

class ActionController::Base

  def self.hobo_user_controller(model=nil)
    @model = model if model
    include Hobo::ModelController
    include Hobo::UserController
  end

  def self.hobo_model_controller(model=nil)
    @model = model if model
    include Hobo::ModelController
  end

  def self.hobo_controller(model=nil)
    include Hobo::Controller
  end

end

class ActiveRecord::Base
  def self.hobo_model
    include Hobo::Model
  end
  def self.hobo_user_model(login_attr=nil, &b)
    include Hobo::Model
    include Hobo::User
    set_login_attr(login_attr, &b) if login_attr
  end
end

# Default settings

Hobo.developer_features = ["development", "test"].include?(RAILS_ENV) if Hobo.developer_features? == nil
