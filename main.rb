# encoding: UTF-8

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

require 'google/api_client'
require 'google/api_client/client_secrets'
require 'google/api_client/auth/installed_app'

require 'tempfile'

client = Google::APIClient.new(
    :application_name => 'Mail Bot',
    :application_version => '1.0.0'
)

pushbullet = Washbullet::Client.new('v1bK8TSF1M4rM1bRctCi7bkLqCuLzJpTQ6ujxIjPKQYUe')

gmail = client.discovered_api('gmail', 'v1')
drive = client.discovered_api('drive', 'v2')

client_secrets = Google::APIClient::ClientSecrets.load

flow = Google::APIClient::InstalledAppFlow.new(
    client_id: client_secrets.client_id,
    client_secret: client_secrets.client_secret,
    scope: ['https://mail.google.com/', 'https://www.googleapis.com/auth/drive']
)

client.authorization = flow.authorize

black_list = ['google_logo.png', 'google.png', 'logo.png']

next_page_token = nil

loop do

  mails = client.execute(
      api_method: gmail.users.messages.list,
      parameters: {
          userId: 'ardialex68@gmail.com',
          maxResults: 53,
          pageToken: next_page_token,
          q: '!in:chats in:inbox is:unread'
      }
  )

  mails.data.messages.each do |mail|
    cpt = 0
    message = client.execute(
        api_method: gmail.users.messages.get,
        parameters: {
            userId: 'ardialex68@gmail.com',
            id: mail.id
        }
    )
    attach = false
    message.data.payload.headers.each do |header|
      puts "#{mail.id}  #{header.value}" if header.name == 'Date'
    end
    client.execute(
        api_method: gmail.users.messages.modify,
        parameters: {
            userId: 'ardialex68@gmail.com',
            id: mail.id,
        },
        body_object: {
            removeLabelIds: ['UNREAD']
        }
    )
    next if message.data.payload.parts.empty?
    message.data.payload.parts.each do |part|
      attach = true if part.body['attachmentId']
    end
    next unless attach
    file_name = message.data.payload.parts[1].filename
    file_type = message.data.payload.parts[1].mimeType
    next if black_list.include? file_name
    attachment = client.execute(
        api_method: gmail.users.messages.attachments.get,
        parameters: {
            userId: 'ardialex68@gmail.com',
            messageId: message.data.id,
            id: message.data.payload.parts[1].body.attachmentId
        }
    )

    puts "  #{file_name}"
    file = Tempfile.new(file_name, :encoding => 'ascii-8bit')
    file.binmode
    file.write Base64.urlsafe_decode64(JSON.parse(attachment.response.env.body)['data'])
    file.close
    file = File.open(file)

    dir = client.execute(api_method: drive.files.list,
                         parameters: {q: 'title = \'Attachments\''}
    )
    dir_id = dir.data.items[0]['id']
    files_list = client.execute(api_method: drive.files.list,
                                parameters: {q: "'#{dir_id}' in parents and trashed = false"}
    )
    files_list.data.items.each do |dir_file|
      if dir_file.title.chomp("#{/( \(\d+(\)))/.match(dir_file.title)}#{File.extname(dir_file.title)}") == file_name.chomp(File.extname(file_name)) && File.extname(dir_file.title) == File.extname(file_name)
        cpt += 1
      end
    end
    media = Google::APIClient::UploadIO.new(file, file_type, file_name)
    if cpt >= 1
      title = "#{file_name.chomp(File.extname(file_name))} (#{cpt+1})#{File.extname(file_name)}"
    else
      title = "#{file_name.chomp(File.extname(file_name))}#{File.extname(file_name)}"
    end
    metadata = {
        title: title,
        parents: [{
                      kind: 'drive#fileLink',
                      id: dir_id
                  }]
    }
    insert_file = client.execute(api_method: drive.files.insert,
                                 parameters: {uploadType: 'multipart'},
                                 body_object: metadata,
                                 media: media)
    file_url = insert_file.data['webContentLink']
    devices = Hash.new
    pushbullet.devices.env.body['devices'].each do |device|
      if device['active']
        devices["#{device['nickname']}"] = device['iden']
      end
    end
    devices.each_value do |device|
      pushbullet.push_link(device, 'New attachment', file_url, title)
    end
    file.close
  end

  next_page_token = mails.data['nextPageToken']
  break unless next_page_token

end
