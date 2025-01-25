require "sinatra"
require "dotenv/load"
require "aws-sdk-s3"
require "aws-sdk-textract"
require "aws-sdk-bedrock"
require "securerandom"
require "json"

set :bind, "0.0.0.0"
set :port, 3000

S3_BUCKET_NAME = ENV["S3_BUCKET_NAME"]

get "/" do
  <<-HTML
  <html>
  <head><title>Resume Parser POC</title></head>
  <body>
    <h1>Upload Your Resume (PDF)</h1>
    <form action="/upload" method="post" enctype="multipart/form-data">
      <input type="file" name="pdf" accept="application/pdf" />
      <button type="submit">Upload</button>
    </form>
  </body>
  </html>
  HTML
end

post "/upload" do
  file = params[:pdf]
  return "No file uploaded or file is invalid." unless file && file[:tempfile]

  s3_key = upload_to_s3(file)
  raw_text = extract_text_from_pdf(s3_key)
  parsed_json = parse_resume_with_bedrock(raw_text)

  content_type :json
  parsed_json.to_json
end

def upload_to_s3(file)
  s3 = Aws::S3::Resource.new
  bucket = s3.bucket(S3_BUCKET_NAME)
  key = "pdf/#{SecureRandom.uuid}.pdf"
  bucket.object(key).upload_file(file[:tempfile].path)
  key
end

def extract_text_from_pdf(s3_key)
  textract = Aws::Textract::Client.new
  start_resp = textract.start_document_text_detection(
    document_location: {
      s3_object: {
        bucket: S3_BUCKET_NAME,
        name: s3_key
      }
    }
  )
  job_id = start_resp.job_id

  loop do
    resp = textract.get_document_text_detection(job_id: job_id)
    case resp.job_status
    when "SUCCEEDED"
      return resp.blocks.select { |b| b.block_type == "LINE" }.map(&:text).join("\n")
    when "FAILED"
      raise "Textract job failed"
    else
      sleep 2
    end
  end
end

def parse_resume_with_bedrock(text)
  bedrock = Aws::Bedrock::Client.new
  prompt = <<~PROMPT
    You are a resume parser. Given the following resume text,
    extract the data into this JSON format:
    {
      "name": "...",
      "email": "...",
      "phone": "...",
      "skills": [...],
      "summary": "...",
      "years_of_experience": 0
    }
    Resume Text:
    "#{text}"
    Return only valid JSON. If unsure, do your best guess.
  PROMPT

  response = bedrock.invoke_model(
    model_identifier: "amazon.titan-tg1-lite",
    body: {
      prompt: prompt,
      max_tokens: 500,
      temperature: 0.0
    }.to_json
  )

  raw_output = JSON.parse(response.body.read)["completion"] rescue ""
  JSON.parse(raw_output) rescue { error: "Model did not return valid JSON", raw_output: raw_output }
end
