require 'ruby-filemagic'
require 'fileutils'

###
# Configuration
###

def boolean_env env_var
  ENV[env_var] and ENV[env_var].downcase == 'true'
end

if ENV['MU_APPLICATION_FILE_STORAGE_PATH'] and ENV['MU_APPLICATION_FILE_STORAGE_PATH'].start_with?('/')
  Mu::log.fatal "MU_APPLICATION_FILE_STORAGE_PATH (#{ENV['MU_APPLICATION_FILE_STORAGE_PATH']}) must be relative"
  exit
else
  FileUtils.mkdir_p "/share/#{ENV['MU_APPLICATION_FILE_STORAGE_PATH']}"
end

configure do
  set :relative_storage_path, (ENV['MU_APPLICATION_FILE_STORAGE_PATH'] || '').chomp('/')
  set :storage_path, "/share/#{(ENV['MU_APPLICATION_FILE_STORAGE_PATH'] || '')}".chomp('/')
  set :file_resource_base, (ENV['FILE_RESOURCE_BASE'] || '')
  set :validate_readable_metadata, boolean_env('VALIDATE_READABLE_METADATA')
end

file_magic = FileMagic.new(FileMagic::MAGIC_MIME)


###
# Vocabularies
###
DC = RDF::Vocab::DC
NFO = RDF::Vocabulary.new('http://www.semanticdesktop.org/ontologies/2007/03/22/nfo#')
NIE = RDF::Vocabulary.new('http://www.semanticdesktop.org/ontologies/2007/01/19/nie#')
DBPEDIA = RDF::Vocabulary.new('http://dbpedia.org/ontology/')


###
# Supporting functions
###
def get_file_info file_uuid
  query = " SELECT ?uri ?name ?format ?size ?extension FROM <#{graph}> WHERE {"
  query += "   ?uri <#{MU_CORE.uuid}> #{Mu::sparql_escape_string(file_uuid)} ;"
  query += "        <#{NFO.fileName}> ?name ;"
  query += "        <#{DC.format}> ?format ;"
  query += "        <#{DBPEDIA.fileExtension}> ?extension ;"
  query += "        <#{NFO.fileSize}> ?size ."
  query += " }"
  Mu::query(query)
end

class UnauthorizedError < StandardError; end

###
# POST /files
# Upload a new file. Results in 2 new nfo:FileDataObject resources: one representing
# the uploaded file and one representing the persisted file on disk generated from the upload.
#
# Accepts multipart/form-data with a 'file' parameter containing the file to upload
#
# Returns 201 on successful upload of the file
#         400 if X-Rewrite header is missing
#             if file param is missing
###
post '/files/?' do
  rewrite_url = Mu::Helpers::rewrite_url_header(request)
  Mu::Helpers::error('X-Rewrite-URL header is missing.') if rewrite_url.nil?
  Mu::Helpers::error('File parameter is required.') if params['file'].nil?

  begin
    tempfile = params['file'][:tempfile]

    upload_resource_uuid = Mu::generate_uuid()
    upload_resource_name = params['file'][:filename]
    upload_resource_uri = "#{settings.file_resource_base}#{upload_resource_uuid}"

    file_format = file_magic.file(tempfile.path)
    file_extension = upload_resource_name.split('.').last
    file_size = File.size(tempfile.path)

    file_resource_uuid = Mu::generate_uuid()
    file_resource_name = "#{file_resource_uuid}.#{file_extension}"
    file_resource_uri = file_to_shared_uri(file_resource_name)

    now = DateTime.now

    physical_file_path = "#{settings.storage_path}/#{file_resource_name}"

    FileUtils.copy(tempfile.path, physical_file_path)

    query =  " INSERT DATA {"
    query += "   GRAPH <#{Mu::graph}> {"
    query += "     #{Mu::sparql_escape_uri(upload_resource_uri)} a <#{NFO.FileDataObject}> ;"
    query += "         <#{NFO.fileName}> #{upload_resource_name.sparql_escape} ;"
    query += "         <#{MU_CORE.uuid}> #{upload_resource_uuid.sparql_escape} ;"
    query += "         <#{DC.format}> #{file_format.sparql_escape} ;"
    query += "         <#{NFO.fileSize}> #{Mu::sparql_escape_int(file_size)} ;"
    query += "         <#{DBPEDIA.fileExtension}> #{file_extension.sparql_escape} ;"
    query += "         <#{DC.created}> #{now.sparql_escape} ;"
    query += "         <#{DC.modified}> #{now.sparql_escape} ."
    query += "     #{Mu::sparql_escape_uri(file_resource_uri)} a <#{NFO.FileDataObject}> ;"
    query += "         <#{NIE.dataSource}> #{Mu::sparql_escape_uri(upload_resource_uri)} ;"
    query += "         <#{NFO.fileName}> #{file_resource_name.sparql_escape} ;"
    query += "         <#{MU_CORE.uuid}> #{file_resource_uuid.sparql_escape} ;"
    query += "         <#{DC.format}> #{file_format.sparql_escape} ;"
    query += "         <#{NFO.fileSize}> #{Mu::sparql_escape_int(file_size)} ;"
    query += "         <#{DBPEDIA.fileExtension}> #{file_extension.sparql_escape} ;"
    query += "         <#{DC.created}> #{now.sparql_escape} ;"
    query += "         <#{DC.modified}> #{now.sparql_escape} ."
    query += "   }"
    query += " }"
    Mu::update(query)

    if settings.validate_readable_metadata && get_file_info(file_resource_uuid).empty?
      raise UnauthorizedError.new "Could not read metadata of file."
    else
      content_type 'application/vnd.api+json'
      status 201
      {
        data: {
          type: 'files',
          id: upload_resource_uuid,
          attributes: {
            name: upload_resource_name,
            format: file_format,
            size: file_size,
            extension: file_extension
          }
        },
        links: {
          self: "#{rewrite_url.chomp '/'}/#{upload_resource_uuid}"
        }
      }.to_json
    end
  rescue UnauthorizedError => e
    Mu::log.warn "#{e} Cleaning up."
    File.delete physical_file_path if File.exist? physical_file_path
    status 403
  rescue SPARQL::Client::MalformedQuery, SPARQL::Client::ClientError, SPARQL::Client::ServerError => e
    Mu::log.warn "Something went wrong while upload file. Cleaning up. #{e}"
    File.delete physical_file_path if File.exist? physical_file_path
    status 500
  end
end

###
# GET /files/:id
# Get metadata of the file with the given id
#
# Returns 200 containing the file with the specified id
#         404 if a file with the given id cannot be found
###
get '/files/:id' do
  rewrite_url = Mu::rewrite_url_header(request)
  error('X-Rewrite-URL header is missing.') if rewrite_url.nil?

  result = get_file_info query(params['id'])

  return status 404 if result.empty?
  result = result.first

  content_type 'application/vnd.api+json'
  status 200
  {
    data: {
      type: 'files',
      id: params['id'],
      attributes: {
        name: result[:name].value,
        format: result[:format].value,
        size: result[:size].value,
        extension: result[:extension].value
      }
    },
    links: {
      self: rewrite_url
    }
  }.to_json
end

###
# GET /files/:id/download?name=foo.pdf
#
# @param name [string] Optional name of the downloaded file
#
# Returns 200 with the file content as attachment
#         404 if a file with the given id cannot be found
#         500 if the file is available in the database but not on disk
###
get '/files/:id/download' do
  query = " SELECT ?fileUrl FROM <#{Mu::graph}> WHERE {"
  query += "   ?uri <#{MU_CORE.uuid}> #{Mu::sparql_escape_string(params['id'])} ."
  query += "   ?fileUrl <#{NIE.dataSource}> ?uri ."
  query += " }"
  result = Mu::query(query)

  return status 404 if result.empty?

  url = result.first[:fileUrl].value
  path = shared_uri_to_path(url)

  filename = params['name']
  filename ||= File.basename(path)

  if params['content-disposition'] and params['content-disposition'].casecmp? 'inline'
    disposition = 'inline'
  else
    disposition = 'attachment'
  end

  if File.file?(path)
    send_file path, disposition: disposition, filename: filename
  else
    Mu::Helpers::error("Could not find file in path. Check if the physical file is available on the server and if this service has the right mountpoint.", 500)
  end
end

###
# DELETE /files/:id
# Delete a file and its metadata
#
# Returns 204 on successful removal of the file and metadata
#         404 if a file with the given id cannot be found
###
delete '/files/:id' do
  query = " SELECT ?uri ?fileUrl FROM <#{Mu::graph}> WHERE {"
  query += "   ?uri <#{MU_CORE.uuid}> #{Mu::sparql_escape_string(params['id'])} ."
  query += "   ?fileUrl <#{NIE.dataSource}> ?uri ."
  query += " }"
  result = Mu::query(query)

  return status 404 if result.empty?

  # NOTE: this is split in two queries because it's lighter on the
  # triplestore.  Ideally mu-auth can split these queries in smarter and
  # lighter way to alleviate the triplestore when the data lives in more
  # than one graph.

  delete_query = "
    DELETE WHERE {
      GRAPH <#{Mu::graph}> {
        <#{result.first[:uri]}> a <#{NFO.FileDataObject}> ;
          <#{NFO.fileName}> ?upload_name ;
          <#{MU_CORE.uuid}> ?upload_id ;
          <#{DC.format}> ?upload_format ;
          <#{DBPEDIA.fileExtension}> ?upload_extension ;
          <#{NFO.fileSize}> ?upload_size ;
          <#{DC.created}> ?upload_created ;
          <#{DC.modified}> ?upload_modified .
      }
    }
   ;
   DELETE WHERE {
    GRAPH <#{Mu::graph}> {
      <#{result.first[:fileUrl]}> a <#{NFO.FileDataObject}> ;
        <#{NIE.dataSource}> <#{result.first[:uri]}> ;
        <#{NFO.fileName}> ?fileName ;
        <#{MU_CORE.uuid}> ?id ;
        <#{DC.format}> ?format ;
        <#{DBPEDIA.fileExtension}> ?extension ;
        <#{NFO.fileSize}> ?size ;
        <#{DC.created}> ?created ;
        <#{DC.modified}> ?modified .
    }
  }
  "
  Mu::update(delete_query)

  url = result.first[:fileUrl].value
  path = shared_uri_to_path(url)
  File.delete path if File.exist? path

  status 204
end

###
# Helpers
###
def shared_uri_to_path(uri)
  uri.sub('share://', '/share/')
end

def file_to_shared_uri(file_name)
  if settings.relative_storage_path and not settings.relative_storage_path.empty?
    return "share://#{settings.relative_storage_path}/#{file_name}"
  else
    return "share://#{file_name}"
  end
end
