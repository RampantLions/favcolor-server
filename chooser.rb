# encoding: utf-8
# Copyright 2012 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#  
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
require 'sinatra'
require './body'
require './database'
require './forms'
require './color'
require './rp'

module Chooser

  TEXT_HTML = { 'Content-type' => 'text/html; charset=utf-8' }

  class Chooser < Sinatra::Base
    enable :sessions

    ### App code

    # Home page
    get '/' do

      # active session?
      email = session[:logged_in]
      if email
        # Session is active, branch to favorite-color app
        account = database.find email
        s = Color.chooser account
        [200, TEXT_HTML, s]

      else
        # No session, they have to log in
        redirect '/account-login'
      end
    end
    
    # Save favorite color, after they've picked it
    post '/set-color' do
      account = database.find session[:logged_in]
      params = Body::parse_body request
      account['color'] = params['color']
      database.save account
      redirect '/'
    end

    ### Identity/Authentication/Authorization code

    # Come here to log in
    get '/account-login' do
      p = Page.new('Login', ac_dot_js(request))
      p.h2! 'Welcome to FavColor!'
      p.payload! Forms.login(request)
      [200, TEXT_HTML, p.to_s]
    end

    # Google comes back here with redirect
    get '/gauth-redirect' do
      if params['error']
        auth_failed params['error_description']
      elsif params['state']
        # successful login with this email
        email = params['state']
        account = database.find email
        if account
          session[:logged_in] = email
          update_ac_js account
        else
          read_google_account(params['code'], request, session)
        end
      else
        read_google_account(params['code'], request, session)
      end
    end

    def read_google_account(code, request, session)
      google_account = Account.new(RP::fetch_google_account(code, request))
      email = google_account['email']
      existing_account = database.find email
      if existing_account
        ['displayName', 'photoUrl'].each do |field|
          existing_account[field] = google_account[field]
        end
        google_account = existing_account
      end

      database.save google_account
      session[:logged_in] = email
      update_ac_js google_account
    end

    # Come here to register a new account
    get '/account-create' do
      p = Page.new('First-time Login', ac_dot_js(request))
      p.h2! 'Welcome to FavColor!'
      p.payload! Forms.register(request)
      [200, TEXT_HTML, p.to_s]
    end

    # ac.js comes here to see if we know this person
    post '/account-status' do
      params = Body::parse_body(request)

      json = nil
      email = params['email']
      if params['authUrl'].eql? 'http://google.com'
        redirect =  RP::google_auth_uri(request, email)
        json = "{ \"authUri\" : \"#{redirect}\" }"
      else
        json =
          '{"registered":' + ((database.find email) ? 'true' : 'false') + '}'
      end
      [200, { 'Content-type' => 'application/json' }, json]
    end

    # Kill session on logout
    post '/logout' do
      session[:logged_in] = nil
      redirect '/'
    end

    # Come here after registering, to save a new account
    post '/new-login' do
      params = Body::parse_body request
      email = params['email']

      # is there already an account?
      if database.find(email)
        redirect '/dupe'

      else
        # We really have a new account, persist it & start session
        account = Account.new(params)
        database.save account
        session[:logged_in] = email
        update_ac_js account
      end
    end

    # tried to register an account with an existing email address
    get '/dupe' do
      p = Page.new "Duplicate account!"
      p.h2! "Sorry, that email is taken."
      p.payload! Forms.dupe
      [200, TEXT_HTML, p.to_s]
    end

    # attempt to log in an existing account
    post '/done-login' do
      params = Body::parse_body request
      email = params['email']
      account = database.find email

      if account
        # we know this person, check the password
        if account.check_password(params['password'])

          # success! Establish a session
          session[:logged_in] = email
          update_ac_js account

        else
          # wrong password or email
          auth_failed 'Incorrect email or password.'
        end

      else
        # Apparently a new user
        redirect '/account-create'
      end
    end

    def auth_failed problem
      p = Page.new 'Authorization failed'
      p.h2! 'Authorization failed'
      p.payload! "<p>#{problem} [<a href='/'>Try again</a>]</p>"
      [403, TEXT_HTML, p.to_s]
    end

    # will redirect back to '/'
    def update_ac_js account
      fields = "storeAccount: {\n"
      ['email', 'displayName', 'photoUrl', 'authUrl'].each do |name|
        field = account[name]
        fields += "#{name}: \"#{field}\",\n" if field && !field.empty?
      end
      fields += '}'
      p = Page.new('Update ac.js', ac_dot_js(request, fields))
      p.h2! 'Updating AccountChooser' # user shouldn't see this
      [200, TEXT_HTML, p.to_s]
    end

    MARKETING_HEADERS = {
      'Content-type' => 'text/html; charset=utf-8',
      "Access-Control-Allow-Origin" => "*",
      "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
      "Access-Control-Max-Age" => "86400"
    }
    MARKETING_TEXT = "<p style='background: #ddaaaa;text-align: center'>" +
      "FavColor — We know your favorite!</p>"

    get '/login-marketing' do
      [ 200, MARKETING_HEADERS, MARKETING_TEXT ]
    end

    ### Utility code

    private
    AC_JS = '<script type="text/javascript" ' +
      'src="https://www.accountchooser.com/ac.js">' + "\n" +
      "uiConfig: { title: \"Log in to FavColor\", "

    def ac_dot_js(req, extras = '')
      branding = "branding: \"#{req.scheme}://#{req.host}:#{req.port}/" +
        "login-marketing\"}"
      comma = extras.empty? ? '' : ','
      AC_JS + branding + comma + "\n" + extras + '</script>'
    end

    def logger
      @logger = Logger.new(STDOUT) unless @logger
      @logger
    end

    def database
      @database = Database.new unless @database
      @database
    end
  end
end

