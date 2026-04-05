## Test Level
Intermediate DevOps For AWS.

## Assignment Time Frame
Max: 3 days (less is better).

## Scenario
Your company has developed 2 WebApps:
1. DotNet web API with Swagger.

Both web apps connect to a MySql RDS:
1. UserName: tempAdmin
2. UserPwd: !tempAdmin954*
3. Please configure the app config file accordingly

These are provided to you by our devs:
1. Web app binaries ZIPs
2. Web app sources ZIPs 
2. All SQL DDL for the apps

As a DevOps engineer, you've been tasked with setting up the infrastructure and deployment process for these applications on AWS.
Please use your own AWS account for this test.

## Tasks

0. Version Control
   - Initialize a Git repository for your work.
   - Create a meaningful commit history as you complete each task.
   - Push your repository to a public GitHub repository.

1. AWS Architecture
   - Create a basic architecture diagram for hosting this web applications on AWS.
   - Include all necessary components.
   - Briefly explain why you chose this architecture.

2. Infrastructure as Code
   - Write a basic Terraform/CloudFormation/CDK script that creates:
     - An S3 bucket
     - An EC2 instance (t2.micro, Ubuntu)
     - An RDS (MySql) for the apps database
     - All components should be able to communicate correctly internally.
     - External Users should be able to access the Swagger from port 80/443.
   - Explain what each part of your template does.

3. Deployment Script
   - Write a bash script that does the following:
     - Updates the system
     - Installs all necessary components to run the web apps correctly
     - Copies a pre-built application from an S3 bucket to the EC2 instance
     - Starts the application

4. Monitoring and Logging
   - Configure CloudWatch for monitoring EC2, RDS and applications
   - Set up centralized logging using CloudWatch Logs

5. CI/CD Pipeline (Conceptual)
   - Describe the steps you would include in a basic CI/CD pipeline for this application.
   - Explain what tools you might use and why.

## Submission
- Please submit your work as a GitHub repository containing all code, scripts, written answers, screenshots of cloud console.
- Include all necessary diagrams, please use www.drawio.com.
- Include a README.md file with any necessary explanations / instructions.


## Note to Candidates
- It's okay if you're not sure about everything. We're interested in your thought process and your ability to learn.
- Feel free to use online resources, but make sure you understand and can explain what you've done.
- If you make any assumptions, please state them clearly.

## Evaluation Criteria
- Proper use of Git for version control
- Cloud infra budgeting control and limit
- Understanding of basic AWS services and best practices
- Ability to write and explain simple infrastructure as code
- Basic scripting skills
- Awareness of monitoring and its importance
- Understanding of CI/CD concepts
- Communication skills
