# Resume Parser POC (Pure Ruby / Sinatra)

This is a simple proof-of-concept application in pure Ruby (using the Sinatra microframework) that:

1. Uploads a PDF resume to an S3 bucket
2. Uses Amazon Textract to extract the text from the PDF
3. Calls an AWS Bedrock foundation model to parse the text into JSON

## Prerequisites

- Ruby 3.2.2
- AWS Credentials with permissions to:
  - Read/Write to S3
  - Use Amazon Textract
  - Use AWS Bedrock
- An existing S3 bucket (replace my-resume-poc-uploads with your bucket name in `app.rb`)

## Setup

1. Install Dependencies:

   ```bash
   bundle install


