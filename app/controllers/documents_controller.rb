class DocumentsController < ApplicationController

  before_action :set_config

  include RDF

  # POST /documents
  def create
    uploaded_file = params[:file]

    document = {}
    document[:id] = SecureRandom.uuid
    document[:name] = "#{document[:id]}.#{uploaded_file.original_filename.split('.').last}"
    file_path = file_path(document[:name])
    document[:href] = uri(document[:name])
    document[:format] = uploaded_file.content_type
    File.open(file_path, 'wb') { |f| f.write(uploaded_file.read) }
    document[:size] = File.size(file_path)
    now = DateTime.now.xmlschema

    query =  " INSERT DATA {"
    query += "   GRAPH <#{@graph}/#{params[:project]}> {"
    query += "     <#{document[:href]}> a <#{NFO.FileDataObject}> ;"
    query += "         <#{NFO.fileName}> \"#{document[:name]}\" ;"
    query += "         <#{DC.identifier}> \"#{document[:id]}\" ;"
    query += "         <#{DC.format}> \"#{document[:format]}\" ;"
    query += "         <#{NFO.fileSize}> \"#{document[:size]}\"^^xsd:integer ;"
    query += "         <#{NFO.fileUrl}> \"file://#{file_path}\" ;"
    query += "         <#{DC.created}> \"#{now}\"^^xsd:dateTime ;"
    query += "         <#{DC.modified}> \"#{now}\"^^xsd:dateTime ."
    # TODO add creator/contributor
    query += "   }"
    query += " }"

    @sparql_client.update(query)

    render json: { :document => document }, status: :ok
  end

  # GET /documents/:id
  def show
    name = "#{params[:id]}.#{params[:format]}"
    send_file file_path(name), disposition: 'attachment'
  end

  # DELETE /documents/:id
  def destroy
    file_name = "#{params[:id]}.#{params[:format]}"
    path = file_path(file_name)
    File.delete path if File.exist? path

    query =  " WITH <#{@graph}/#{params[:project]}> "
    query += " DELETE {"
    query += "   <#{uri(file_name)}> a <#{NFO.FileDataObject}> ;"
    query += "       <#{NFO.fileName}> ?fileName ;"
    query += "       <#{DC.identifier}> ?id ;"
    query += "       <#{DC.format}> ?format ;"
    query += "       <#{NFO.fileSize}> ?fileSize ;"
    query += "       <#{NFO.fileUrl}> ?fileUrl ;"
    query += "       <#{DC.created}> ?created ;"
    query += "       <#{DC.modified}> ?modified ."
    # TODO remove creator/contributor
    query += " }"
    query += " WHERE {"
    query += "   <#{uri(file_name)}> a <#{NFO.FileDataObject}> ;"
    query += "       <#{NFO.fileName}> ?fileName ;"
    query += "       <#{DC.identifier}> ?id ;"
    query += "       <#{DC.format}> ?format ;"
    query += "       <#{NFO.fileSize}> ?fileSize ;"
    query += "       <#{NFO.fileUrl}> ?fileUrl ;"
    query += "       <#{DC.created}> ?created ;"
    query += "       <#{DC.modified}> ?modified ."
    # TODO remove creator/contributor
    query += " }"
    @sparql_client.update(query)

    render json: nil, status: :no_content
  end


  # Exception handling

  rescue_from ActionController::MissingFile do |e|
    render json: { status: 'Not found' }, status: :not_found
  end



  private

  def set_config
    @storage_location = Rails.application.config.x.file.storage_location
    @graph = Rails.application.config.x.rdf.graph_base
    @sparql_access_point = Rails.application.config.x.rdf.sparql_endpoint
    @sparql_client = SPARQL::Client.new(@sparql_access_point)
  end

  def uri(name)
    "#{@graph}documents/#{name}"
  end

  def file_path(name)
    "#{@storage_location}/#{name}"
  end

end
