require 'digest/sha1'
require 'mysql2'
require 'sinatra/base'

require 'mysql2-cs-bind'
require 'redis'
require 'oj'
require 'hiredis'
require 'zstd-ruby'
require 'dalli'
require 'rack/cache'

class App < Sinatra::Base
  use Rack::Cache

  configure do
    set :session_secret, 'tonymoris'
    set :public_folder, File.expand_path('../../public', __FILE__)
    set :avatar_max_size, 1 * 1024 * 1024

    enable :sessions
  end

  configure :development do
    require 'sinatra/reloader'
    register Sinatra::Reloader
  end

  helpers do
    def user
      return @_user unless @_user.nil?

      user_id = session[:user_id]
      return nil if user_id.nil?

      @_user = db_get_user(user_id)
      if @_user.nil?
        params[:user_id] = nil
        return nil
      end

      @_user
    end
  end

  get '/initialize' do
    db.query("DELETE FROM user WHERE id > 1000")
    db.query("DELETE FROM image WHERE id > 1001")
    db.query("DELETE FROM channel WHERE id > 10")
    db.query("DELETE FROM message WHERE id > 10000")
    db.query("TRUNCATE haveread")
    redis.flushall
    204
  end

  get '/' do
    if session.has_key?(:user_id)
      return redirect '/channel/1', 303
    end
    erb :index
  end

  get '/channel/:channel_id' do
    if user.nil?
      return redirect '/login', 303
    end

    @channel_id = params[:channel_id].to_i
    @channels, @description = get_channel_list_info(@channel_id)
    erb :channel
  end

  get '/register' do
    erb :register
  end

  post '/register' do
    name = params[:name]
    pw = params[:password]
    if name.nil? || name.empty? || pw.nil? || pw.empty?
      return 400
    end
    begin
      user_id = register(name, pw)
    rescue Mysql2::Error => e
      return 409 if e.error_number == 1062
      raise e
    end
    session[:user_id] = user_id
    redirect '/', 303
  end

  get '/login' do
    erb :login
  end

  post '/login' do
    name = params[:name]
    user = db.xquery('SELECT id, password, salt FROM user WHERE name = ?', name).first
    if user.nil? || user[:password] != Digest::SHA1.hexdigest(user[:salt] + params[:password])
      return 403
    end
    session[:user_id] = user[:id]
    redirect '/', 303
  end

  get '/logout' do
    session[:user_id] = nil
    redirect '/', 303
  end

  post '/message' do
    user_id = session[:user_id]
    message = params[:message]
    channel_id = params[:channel_id]
    if user_id.nil? || message.nil? || channel_id.nil? || user.nil?
      return 403
    end
    db_add_message(channel_id.to_i, user_id, message)
    204
  end

  get '/message' do
    user_id = session[:user_id]
    if user_id.nil?
      return 403
    end

    channel_id = params[:channel_id].to_i
    last_message_id = params[:last_message_id].to_i
    rows = get_messages_1(last_message_id, channel_id)
    response = []
    rows.each do |row|
      r = {}
      r[:id] = row[:id]
      r[:user] = get_user(row[:user_id])
      r[:date] = row[:created_at].strftime("%Y/%m/%d %H:%M:%S")
      r[:content] = row[:content]
      response << r
    end
    response.reverse!

    max_message_id = rows.nil? ? 0 : rows.map { |row| row[:id] }.max
    p max_message_id
    db.xquery('INSERT INTO haveread (user_id, channel_id, message_id, updated_at, created_at) VALUES (?, ?, ?, NOW(), NOW()) ON DUPLICATE KEY UPDATE message_id = ?, updated_at = NOW()', user_id, channel_id, max_message_id, max_message_id)

    content_type :json
    response.to_json
  end

  get '/fetch' do
    user_id = session[:user_id]
    if user_id.nil?
      return 403
    end

    sleep 0.3

    channels = get_channels()

    res = []
    channels.each do |channel|
      channel_id = channel[:id]
      row = db.xquery('SELECT * FROM haveread WHERE user_id = ? AND channel_id = ?', user_id, channel_id).first
      r = {}
      r[:channel_id] = channel_id
      r[:unread] = if row.nil?
        db.xquery('SELECT COUNT(id) as cnt FROM message WHERE channel_id = ?', channel_id).first[:cnt]
      else
        db.xquery('SELECT COUNT(id) as cnt FROM message WHERE channel_id = ? AND ? < id', channel_id, row[:message_id]).first[:cnt]
      end
      res << r
    end

    content_type :json
    res.to_json
  end

  get '/history/:channel_id' do
    if user.nil?
      return redirect '/login', 303
    end

    @channel_id = params[:channel_id].to_i

    @page = params[:page]
    if @page.nil?
      @page = '1'
    end
    if @page !~ /\A\d+\Z/ || @page == '0'
      return 400
    end
    @page = @page.to_i

    n = 20
    rows = db.xquery("SELECT id, user_id, created_at, content FROM message WHERE channel_id = ? ORDER BY id DESC LIMIT #{n} OFFSET #{(@page - 1) * n}", @channel_id)
    @messages = []
    rows.each do |row|
      r = {}
      r[:id] = row[:id]
      r[:user] = get_user(row[:user_id]) 
      r[:date] = row[:created_at].strftime("%Y/%m/%d %H:%M:%S")
      r[:content] = row[:content]
      @messages << r
    end
    @messages.reverse!

    cnt = db.xquery('SELECT COUNT(*) as cnt FROM message WHERE channel_id = ?', @channel_id).first[:cnt].to_f
    @max_page = cnt == 0 ? 1 :(cnt / n).ceil

    return 400 if @page > @max_page

    @channels, @description = get_channel_list_info(@channel_id)
    erb :history
  end

  get '/profile/:user_name' do
    if user.nil?
      return redirect '/login', 303
    end

    @channels, = get_channel_list_info

    user_name = params[:user_name]
    @user = get_user_by_name(user_name)

    if @user.nil?
      return 404
    end

    @self_profile = user[:id] == @user[:id]
    erb :profile
  end
  
  get '/add_channel' do
    if user.nil?
      return redirect '/login', 303
    end

    @channels, = get_channel_list_info
    erb :add_channel
  end

  post '/add_channel' do
    if user.nil?
      return redirect '/login', 303
    end

    name = params[:name]
    description = params[:description]
    if name.nil? || description.nil?
      return 400
    end
    exe = db.xquery('INSERT INTO channel (name, description, updated_at, created_at) VALUES (?, ?, NOW(), NOW())', name, description)
    channel_id = db.query('SELECT LAST_INSERT_ID() AS last_insert_id').first[:last_insert_id]
    redis.del 'channels'
    redirect "/channel/#{channel_id}", 303
  end

  post '/profile' do
    if user.nil?
      return redirect '/login', 303
    end

    if user.nil?
      return 403
    end

    display_name = params[:display_name]
    avatar_name = nil
    avatar_data = nil

    file = params[:avatar_icon]
    unless file.nil?
      filename = file[:filename]
      if !filename.nil? && !filename.empty?
        ext = filename.include?('.') ? File.extname(filename) : ''
        unless ['.jpg', '.jpeg', '.png', '.gif'].include?(ext)
          return 400
        end

        if settings.avatar_max_size < file[:tempfile].size
          return 400
        end

        data = file[:tempfile].read
        digest = Digest::SHA1.hexdigest(data)

        avatar_name = digest + ext
        avatar_data = data
      end
    end

    if !avatar_name.nil? && !avatar_data.nil?
      db.xquery('INSERT INTO image (name, data) VALUES (?, ?)', avatar_name, avatar_data)
      db.xquery('UPDATE user SET avatar_icon = ? WHERE id = ?', avatar_name, user[:id])
    end

    if !display_name.nil? || !display_name.empty?
      db.xquery('UPDATE user SET display_name = ? WHERE id = ?', display_name, user[:id])
    end

    tmp_user = get_user(user[:id])
    redis.del 'user_' + user[:id].to_s
    redis.del 'user_by_name_' + tmp_user[:name]
    redirect '/', 303
  end

  get '/icons/:file_name' do
    cache_control :public, :max_age => 3600
    file_name = params[:file_name]
    data = get_image_data(file_name)
    ext = file_name.include?('.') ? File.extname(file_name) : ''
    mime = ext2mime(ext)
    if !data.nil? && !mime.empty?
      content_type mime
      return data
    end
    404
  end

  private

  def get_messages_1(last_message_id, channel_id)
    db.xquery('SELECT id, user_id, created_at, content FROM message WHERE id > ? AND channel_id = ? ORDER BY id DESC LIMIT 100', last_message_id, channel_id)
  end

  def get_user(id)
    key = 'user_' + id.to_s
    tmp = redis.get(key)
    if tmp then
      return Oj.load(tmp, :mode => :compat, :symbol_keys => true)
    else
      user = db.xquery('SELECT name, display_name, avatar_icon FROM user WHERE id = ?', id).first
      user_json = Oj.dump(user, :mode => :compat, :symbol_keys => true)
      redis.set key, user_json
      return user
    end
  end

  def get_user_by_name(name)
    key = 'user_by_name_' + name
    tmp = redis.get(key)
    if tmp then
      return Oj.load(tmp, :mode => :compat, :symbol_keys => true)
    else
      user = db.xquery('SELECT id, name, display_name, avatar_icon FROM user WHERE name = ?', name).first
      return nil unless user
      p 'sss' + user[:id].to_s
      user_json = Oj.dump(user, :mode => :compat, :symbol_keys => true)
      p user_json
      redis.set key, user_json
      return user
    end
  end

  def get_image_data(name)
    key = 'image_' + name
    tmp = redis.get(key)
    if tmp then
      return tmp
    else
      data = db.xquery('SELECT data FROM image WHERE name = ?', name).first[:data]
      redis.set key, data
      return data
    end
  end

  def get_channels()
    key = 'channels'
    tmp = redis.get(key)
    if tmp then
      return Oj.load(tmp, :mode => :compat, :symbol_keys => true)
    else
      ids = db.query('SELECT id FROM channel')
      rows = Array.new
      ids.each do |id|
          rows << id
      end
      rows_json = Oj.dump(rows, :mode => :compat, :symbol_keys => true)
      redis.set key, rows_json
      return rows
    end
  end

  def db
    return Thread.current[:isucon_db] if Thread.current[:isucon_db]
    client = Mysql2::Client.new(
      host: ENV.fetch('ISUBATA_DB_HOST') { 'localhost' },
      port: ENV.fetch('ISUBATA_DB_PORT') { '3306' },
      username: ENV.fetch('ISUBATA_DB_USER') { 'root' },
      password: ENV.fetch('ISUBATA_DB_PASSWORD') { '' },
      database: 'isubata',
      encoding: 'utf8mb4',
      reconnect: true,
      cache_rows: true,
      init_command: "SET SESSION sql_mode='TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY'"
    )
    client.query_options.merge!(symbolize_keys: true)
    Thread.current[:isucon_db] = client
    client
  end

  def redis
    return Thread.current[:isucon_redis] if Thread.current[:isucon_redis]
    client = Redis.new(:host => "192.168.101.3", :port => 6379, :driver => :hiredis, :tcp_keepalive => 60)
    Thread.current[:isucon_redis] = client
    client
  end

  def compress(data)
    Zstd.compress(data)
  end

  def decompress(data)
    Zstd.decompress(data)
  end

  def db_get_user(user_id)
    db.xquery('SELECT * FROM user WHERE id = ?', user_id).first
  end

  def db_add_message(channel_id, user_id, content)
    statement = db.prepare('INSERT INTO message (channel_id, user_id, content, created_at) VALUES (?, ?, ?, NOW())')
    messages = statement.execute(channel_id, user_id, content)
    statement.close
    messages
  end

  def random_string(n)
    Array.new(20).map { (('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a).sample }.join
  end

  def register(user, password)
    salt = random_string(20)
    pass_digest = Digest::SHA1.hexdigest(salt + password)
    db.xquery('INSERT INTO user (name, salt, password, display_name, avatar_icon, created_at) VALUES (?, ?, ?, ?, ?, NOW())', user, salt, pass_digest, user, 'default.png')
    db.query('SELECT LAST_INSERT_ID() AS last_insert_id').first[:last_insert_id]
  end

  def get_channel_list_info(focus_channel_id = nil)
    channels = db.query('SELECT * FROM channel ORDER BY id').to_a
    description = ''
    channels.each do |channel|
      if channel[:id] == focus_channel_id
        description = channel[:description]
        break
      end
    end
    [channels, description]
  end

  def ext2mime(ext)
    if ['.jpg', '.jpeg'].include?(ext)
      return 'image/jpeg'
    end
    if ext == '.png'
      return 'image/png'
    end
    if ext == '.gif'
      return 'image/gif'
    end
    ''
  end
end
