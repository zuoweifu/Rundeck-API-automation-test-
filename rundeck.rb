require 'time'
require 'net/http'
require 'uri'
require 'net/https'
require 'nokogiri'
require 'rubygems'
require 'excon'
require 'net/smtp'
require 'mail'
require 'date'
require 'optparse'
require 'ostruct'

#command line parser
options = OpenStruct.new
OptionParser.new do |opt|
  opt.on('-d', '--date DATE', ' ') { |o| options.date = o }
  opt.on('-n', '--name NAME', ' ') { |o| options.name = o }
  opt.on('-l', '--loadaverage LOADAVERAGE', ' ') { |o| options.loadaverage = o }
end.parse!

#help
if options.date == nil && options.name == nil && options.loadaverage == nil
    puts "Help:
            --------------------------------------
            -d, --date               expired date 
            -n, --name               job name
            -l, --loadaverage        loadaverage
            --------------------------------------
            "
    exit
end

#alert
if options.date == nil && options.name != nil
    puts "              ----- Please input expired days -----"
    exit
end

if options.date != nil && options.name == nil
    puts "              ----- Please input job name -----"
    exit
end

if options.loadaverage.to_f < 0
    puts "              ----- loadaverage has to be larger than 0 -----"
    exit
end

#Write API_KEY and SERVER here
API_KEY='API KEY'
RUNDECKSERVER = 'RUNDECKSERVER'
RUNDECKPORT = 'RUNDECKPORT'

#Expire days
EXPIRE_DAYS = options.date.to_i
TODAY = (Time.new.to_f * 1000).round
EXPIRE_MILISECONDS = EXPIRE_DAYS * 24 * 60 * 60 * 1000


#send e-mail
def email_report(subject, message_body)
    smtp = { :address => 'emailaddress.com', :port => 000, :domain => 'company.com', :user_name => 'reporting@company.com', :password => 'password', :enable_starttls_auto => true, :openssl_verify_mode => 'none' }
    Mail.defaults do
        delivery_method :smtp, smtp
    end

    mail = Mail.new do
        from     'reporting@company.com'
        to       ['user@company.com']
        subject  subject
        content_type 'text/html; charset=UTF-8'
        body     message_body
    end

    mail.deliver
end

#get system status
def getSystemstatus
    uri = URI(RUNDECKSERVER + ':' + RUNDECKPORT + '/api/14/system/info')
    http = Net::HTTP.new(uri.host, uri.port)
    headers = {
    'Content-Type'=> 'application/json',
    'X-RunDeck-Auth-Token'=> API_KEY 
}
    r = http.get(uri.path, headers)
    return r.body.force_encoding("UTF-8")
end

#get load average
def checkSystemstatus(systeminfo_xml)
    doc = Nokogiri::XML(systeminfo_xml)

    doc.css('//system').each do |system|
       return system.at_css('loadAverage').content
    end
end

#send e-mail when load average over 2.00
def loadAveragewatchdog(loadaverage,maxloadaverage)
    if loadaverage.to_f >= maxloadaverage.to_f
        return true
    end
    return false
end



# API call to get the list of the existing projects on the server.
def listProjects 
    uri = URI(RUNDECKSERVER + ':' + RUNDECKPORT + '/api/1/projects')
    http = Net::HTTP.new(uri.host, uri.port)
    headers = {
    'Content-Type'=> 'application/json',
    'X-RunDeck-Auth-Token'=> API_KEY 
}
    r = http.get(uri.path, headers)
    return r.body.force_encoding("UTF-8")

end

# Returns list of all the project names
def getProjectNames(projectsinfo_xml)
    project_names = Array.new
    doc = Nokogiri::XML(projectsinfo_xml)
    doc.css('//project').each do |project|
    project_names << project.at_css('name').content
    end
    return project_names
end

#API call to get the list of the jobs that exist for a project.
def listJobsForProject(project_mame)
    uri = URI(RUNDECKSERVER + ':' + RUNDECKPORT + '/api/1/jobs')
    params = { 'project' => project_mame }
    headers = {
    'Content-Type'=> 'application/json',
    'X-RunDeck-Auth-Token'=> API_KEY 
}
    connection = Excon.new('http://build01:4440/api/1/jobs')
    return connection.get(:query => { 'project' => project_mame },:headers => {
    'Content-Type'=> 'application/json',
    'X-RunDeck-Auth-Token'=> API_KEY 
}).body.force_encoding("UTF-8")

end


# Returns list of all the jobids
def getJobIDs(jobsinfo_xml)
    jobs = {}
    doc = Nokogiri::XML(jobsinfo_xml)
    doc.css('//job').each do |job|
    job_id = job.at_css('@id').content
    job_name = job.at_css('/name').content
    jobs.store(job_id,job_name)
end
    return jobs
end

# API call to get the list of the executions for a Job.      
def getExecutionsForAJob(job_id)
    uri = URI(RUNDECKSERVER + ':' + RUNDECKPORT + '/api/1/job/' + job_id + '/executions')
    http = Net::HTTP.new(uri.host, uri.port)
    headers = {
    'Content-Type'=> 'application/json',
    'X-RunDeck-Auth-Token'=> API_KEY 
}
    r = http.get(uri.path, headers)
    return r.body.force_encoding("UTF-8")
end

# Returns a dict {'execution_id01': 'execution_date01', 'execution_id02': 'execution_date02', ... }
def getExecutionDate(executionsinfo_xml)
    execid_dates = {}
    doc = Nokogiri::XML(executionsinfo_xml)
     
    doc.css('//execution').each do|execution|
        if  execution.at_css('@status').content == "succeeded"
        execution_id = execution.at_css('@id').content
        if execution.at_css('/date-ended') !=nil
        execution_date = execution.at_css('/date-ended/@unixtime').content.to_i
        execid_dates.store(execution_id,execution_date)
    end
    end
    end
     return execid_dates
end

#API call to delete an execution by ID
def deleteExecution(execution_id)
    uri =  URI(RUNDECKSERVER + ':' + RUNDECKPORT + '/api/12/execution/' + execution_id)
    http = Net::HTTP.new(uri.host, uri.port)
    headers = {'Content-Type'=> 'application/jsonr','X-RunDeck-Auth-Token'=> API_KEY }
    r = http.delete(uri.path, headers)  
    return r
end


#check if execution is expired
def isOlderThanExpireDays(execution_date, today)
    if ((today - execution_date) > EXPIRE_MILISECONDS)
        return true
    end
    return false
end



if options.date != nil && options.name != nil
#go through all executions
projects = getProjectNames(listProjects)
    projects.each do |project|
    #puts 'project:' + project (for debugging)
        jobs = getJobIDs(listJobsForProject(project))
            jobs.each do |jobid,jobname|
            #puts 'jobid:' + jobid (for debugging)
            if options.date != nil
                if jobname == options.name
                    puts "deleting....."
                    getExecutionDate(getExecutionsForAJob(jobid)).each do |id, date|
                        if isOlderThanExpireDays(date,TODAY)     
                            deleteExecution(id)
                        end
                     end
                     puts "deleted all expired executions!"
                end
            end
            end
    end

end


#check loadaverage
if options.loadaverage != nil
body = "rundeck loadAverage is over " 
body += options.loadaverage
body += "The value is "
body += checkSystemstatus(getSystemstatus)
body += "."
if loadAveragewatchdog(checkSystemstatus(getSystemstatus),options.loadaverage.to_f)
    email_report "rundeck report", body
end
end

