require "sinatra"
require "dotenv/load"
require "aws-sdk-s3"
require "aws-sdk-textract"
require "aws-sdk-bedrockruntime"
require "securerandom"
require "json"
require 'pry'

set :bind, "0.0.0.0"
set :port, 3000

S3_BUCKET_NAME = ENV["S3_BUCKET_NAME"]

get "/" do
  erb :index
end

post "/upload" do
  file = params[:pdf]
  return "No file uploaded or file is invalid." unless file && file[:tempfile]

  s3_key = upload_to_s3(file)
  raw_text = extract_text_with_textract(s3_key)
  parsed_json = parse_resume_with_bedrock(raw_text)

  @parsed_json = JSON.pretty_generate(parsed_json)
  erb :result
end

private

def upload_to_s3(file)
  s3 = Aws::S3::Resource.new
  bucket = s3.bucket(S3_BUCKET_NAME)
  key = "pdf/#{SecureRandom.uuid}.pdf"

  bucket.object(key).upload_file(file[:tempfile].path)
  key
end

def extract_text_with_textract(s3_key)
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
      lines = resp.blocks.select { |b| b.block_type == "LINE" }.map(&:text)
      return lines.join("\n")
    when "FAILED"
      raise "Textract job failed"
    else
      sleep 2
    end
  end
end

def parse_resume_with_bedrock(text)
  client = Aws::BedrockRuntime::Client.new
  truncated_text = text.size > 3500 ? "#{text[0..3500]}...(truncated)" : text

  prompt = <<~PROMPT
   You are a specialized resume parser, tasked with analyzing and extracting specific data fields from resumes. Your goal is to process the given resume text and structure the extracted information into the following JSON format:
    {
      "personal_info": {
        "first_name": "",
        "last_name": "",
        "contact": {
          "phone": "",
          "email": "",
          "linkedin": "",
          "github": ""
        },
        "address": {
          "city": "",
          "country": ""
        }
      },
      "objective": "",
      "education": [
        {
          "degree": "",
          "field_of_study": "",
          "university": "",
          "graduation_year": "",
          "gpa": ""
        }
      ],

      "work_experience": [
        {
          "job_title": "",
          "company": "",
          "location": "",
          "start_date": "",
          "end_date": "",
          "responsibilities": []
        }
      ],
      "specializations": [],

      "skills": [],

      "projects": [
        {
          "name": "",
          "description": "",
          "technologies": [],
          "duration": ""
        }
      ],

      "courses": [
        {}
      ],
      "language_courses": [],

      "certifications": [
        {
          "title": "",
          "issuer": "",
          "issue_date": ""
        }
      ],

      "languages": [
        {
          "language": "",
          "proficiency": ""
        }
      ],

      "references": [
        {
          "name": "",
          "relationship": "",
          "company": "",
          "contact": {
            "phone": "",
            "email": ""
          }
        }
      ],
      "years_of_experience": "",
      "about_me": "",
      "unsorted_data": ""
    }
    response_schema.json
    Displaying response_schema.json.

    ### Instructions:
    1. Carefully extract the candidate's name, email, and phone number.
    2. Identify the skills section (e.g., programming languages, tools, methodologies) and list each skill separately in an array.
    3. Parse the references, if available, and include their details (name, relationship, company, contact information).
    4. Estimate the candidate's years of experience based on the roles, timelines, or any other explicit mention in the resume.
    5. Include a concise summary for about_me if present (e.g., objectives or professional summaries).
    6. Place any information you cannot categorize under unsorted_data while preserving the original text.
    7. Return only one valid JSON object in the specified format, and do not include any additional commentary, code blocks, or extraneous formatting.
    8. If certain fields are unavailable or ambiguous, leave them as empty strings, arrays, or objects and provide your best approximation.

    Resume Text:
    "#{truncated_text}"

    ### Additional Notes:
    - Adhere strictly to the JSON format provided.
    - If information is redundant, include it only once in the most appropriate field.
    - Ensure all extracted data is as accurate as possible based on the given resume text.
    - Your output should represent the parsed data in a clean and structured manner.
      PROMPT

  response = client.invoke_model(
    model_id: "amazon.titan-text-lite-v1",
    content_type: "application/json",
    accept: "application/json",
    body: {
      inputText: prompt,
      textGenerationConfig: {
        maxTokenCount: 2048,
        temperature: 0.5
      }
    }.to_json
  )

  parse_bedrock_response(response.body.read)
end

def parse_bedrock_response(raw_response)
  parsed_response = JSON.parse(raw_response) rescue {}
  output_text = parsed_response.dig("results", 0, "outputText") || ""

  clean_json = extract_json(output_text.strip)
  JSON.parse(clean_json) rescue { error: "Invalid JSON output", raw_output: clean_json }
end

def extract_json(text)
  match = text.match(/\{.*\}/m) || text.match(/\[.*\]/m)
  match ? match[0] : ""
end
