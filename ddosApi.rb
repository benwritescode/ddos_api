=begin
  ddosApi.rb
  Ben Jones
  Spring 2012
  DOSR DDOS Failover API
  
  ddosApi.rb: this is a basic API to implement a failover in the case of a DDOS
    attack. This API does not implement DDOS detection per say, but examines the
    time between communications from other servers. The API essentially routes all
    traffic betweent the local server and other servers. More information on
    implementation details may be found throughout the code.
  contents: this file contains the DDOS_API class and all of its necessary code
  Special Note: This API is far from perfect and needs a number of changes to create
    a more effective implementation. Chief among these concerns is a need for a
    better data structure for connections of all types. I hope to address this in
    future revisions
=end

#I will need to methods from net/http and socket
require 'socket'
require 'thread'

#Code for the DOSR API(Denial Of Service Recovery)
class DDOS_API  


  #methods for testing-> lets me get and set variables
  def status_unsure=(array)
    @status_unsure = array
  end

  #main ddos methods and variables
  public
  
  #use this alias to point to the object on the server that is processing data
  @service_object

  #list of who to failover to and who is dependent upon this server
  #fail_to: list of who we could failover to
  #fail_rec: list who we are monitoring in case we need to accept failover-> we are
  # the hot failover for these servers
  #dependents: list of who is dependent upon the local server
  #fail_back_mode: set to true to indicate we are just a hot failover, and false to
  # indicate that we are not a hot failover
  #these lists use the fail_to_sem, fail_rec_sem, and dep_sem mutexes for mutual
  # exclusion
  @fail_to
  @fail_rec
  @dependents
  @fail_back_mode


  #note that this is an array of sockets. The 0th element is the
  # array of connections, 1st element is the source ip, the 2nd element is the 
  # source port, the 3rd element is the last time data was received, the 4th 
  # element is the connection id, and th 5th element is whether the 
  # connection is dead or alive
  #conn_sem is a mutex to provide mutual exclusion
  @connects

  #this class variable stores the local ip 
  @local_ip
  @local_port

  #instance variables for threads should they be needed
  @input_threadT
  @accept_threadT
  @backup_threadT

  #failover_timeout: this constant stores the amount of time to wait for new data
  # before failing over-> note that it will take 2 * @failover_timeout seconds from
  # the last input for a connection to be declared dead
  #status_unsure: array of connections that need to be rechecked to see if they are
  # dead. Uses mutual exclusion
  @failover_timeout
  @status_unsure

  #rec_backups is an instance variable to store the array of backups- each element 
  # is an array that has the timestamp of when the backup was made and the backup 
  # data in marshalled form. 
  #force_backup is how long to wait in seconds before forcing the service to make a 
  # backup to the fail_to connections list
  #dead_connects is a list of connections that have been marked as dead. Not used in
  # this version of the API, but my vision for the future is to use this list to 
  # add fail-over servers back into the list after they come back online
  #rec_back_sem and dead_sem are mutexes to provide mutual exclusion
  @force_backup
  @rec_backups
  @dead_connects

  #associative arrays to store ip to id and id to ip conversions
  #to_id_table: associative array to turn ip and port numbers into id numbers
  #maxId: this is a counter to store the highest id used so far. id_sem must be
  # acquired before this variable can be accessed
  #to_ip_table: hash table to turn id numbers into ip and port combinations
  #ip_sem and id_sem are mutexes for mutual exclusion
  @to_id_table
  @to_ip_table
  @maxId

  #semaphore to lock access to data-> please note that it would not be feasible for
  # me to implement something like priority inheritance, so to avoid priority
  # inversion, these semaphores MUST be waited on in the order that they are listed
  #Update: these semaphores do not work right now, but after I develop a new method
  # for mutual exclusion this same ordering will still apply
  @dead_sem
  @dep_sem
  @ip_sem
  @id_sem
  @status_sem
  @rec_back_sem
  @fail_rec_sem
  @fail_to_sem  
  @conn_sem


  #variables to store the current server state

  #kill stores whether the DDOS API has been shut down or not. If it is true, then it
  # has been shut down. If false, then the API should be running
  #alive stores whether this server is under DDOS attack. If alive is true, then it
  # is not under DDOS attack, and if it is false, then it is under DDOS attack
  @@kill
  @alive

  #here are some basic accessor methods
  def get_failover_connection
    @failover_connect
  end
  def get_failover_timeout
    @failover_timeout
  end
  def get_service_object
    @service_object
  end

  #some setter methods
  #set_service_object(reference *): this function will set the value of service
  # object and also check that the object contains necessary methods
  #Note: the main point of this function is so that I don't have to specify a 
  # service object in the constructor
  def set_service_object=(service_object)
    #set @service_object up as a reference to the service's object and make sure
    # that it can handle the to_yaml, and get_data methods
    begin
      if !service_object.respond_to?("to_yaml", true) or !service_object.respond_to?("get_data", true) or !service_object.respond_to?("load_fail", true) then
         raise
      end
    rescue
      puts "\nService Object lacks needed methods. Must define and implement\n"
      puts "both a load_fail, get_data, and to_yaml method as outlined\n"
      puts "in the documentation"
    end
    @service_object = service_object
  end
  
  
  #these functions are the actual meat of the API
  
  #use the constructor to initialize attributes that dont require processing
  #Note: since this is overloaded, it is possible to pass in completely nil args,
  # which would cause problems
  #fixMe-> add error handling for nil variable conditions
  def initialize(*args)
    failover_timeout, local_ip, local_port, service_object = args
    #set the failover timeout to failover_timeout
    @failover_timeout = failover_timeout

    #set the incoming connection information
    @local_ip = local_ip
    @local_port = local_port

    #set kill to false so that the API will keep processing IO as long as @@kill is
    # not already false or it is not already defined
    if defined?(@@kill).nil? or !@@kill then
      @@kill = false
    end
    @alive = true

    #set up the tables and maxId for conversion between ids and ips
    @to_id_table = {"self" => -1}
    @to_ip_table = {-1 => [@local_ip, @local_port]}
    @maxId = 1

    #set up threads
    #now set up a thread to accept new connections
    server = TCPServer.new(@local_ip, @local_port)
    @accept_threadT = Thread.new(server) {|server| accept_thread(server)}
    #and another thread to handle input
    @input_threadT = Thread.new { input_thread()}
    #and another thread for backups
    @backup_threadT = Thread.new { backup_thread()}

    #and all the connection lists (this will prevent nil assignment problems)
    @fail_to = Array.new(6){[]}
    @fail_rec = Array.new(6){[]}
    @dependents = Array.new(6){[]}
    @connects = Array.new(6){[]}
    @rec_backups = Array.new(6){[]}
    @status_unsure = Array.new(6){[]}
    @dead_connects = Array.new(6){[]}

    set_service_object = service_object if !service_object.nil?
  end

  #config_api: will read in the ip address of the next server to failover to and
  # store the socket in failover_connect
  #Note: this method should be called before using the rest of the API
  #fixMe-> update for new API setup
  def config_api(failover_filename="failover.txt")
    #then read in the failover data from a file
    failover = File.open(failover_filename,"r")

    #use a flag to see if the failover ip is set inside this loop
    failover_socket_set = false

    #now iterate over each line and find the next failover ip and port from the file
    while line = failover.gets do
      #remove the trailing new line character
      line.chomp!

      #split the info into local connection and failover connection info
      local_info, rest_info = line.split("fail_rec")
      #remove whitespace
      local_info.rstrip!
      rest_info.lstrip!
      #read in the local connection info
      local_ip, local_port = local_info.split(" ")
      local_port = local_port.to_i

      #if the last ip read was the ip and port of this server, then use the data in
      # this line. Otherwise, move on 
      if(local_ip == @local_ip) then
        break
      #if the local address could not be found, then use the first entry in the 
      # file
      elsif local_ip.nil?
        failover.rewind
        line = failover.gets
        line.chomp!
        local_info, rest_info = line.split("fail_rec")
        #remove whitespace
        local_info.rstrip!
        rest_info.lstrip!
        #read in the local connection info
        local_ip, local_port = local_info.split(" ")
        local_port = local_port.to_i
        break
      end
    end

    #now separate it into fail_to and fail_rec servers and then into port and ip
    # info before adding it all to the respective lists
    fail_rec, fail_to = rest_info.split("fail_to")
    fail_rec.rstrip
    fail_to.strip
    #split the string on each of the spaces to get out the ports and ips
    fail_rec_array = fail_rec.split(" ")
    fail_to_array = fail_to.split(" ")

    #now read in the fail_rec data
    fail_index = 0
    array_index = 0

    while array_index <= (fail_rec_array.length/ 2) do
      #get the ip and port from the input
      ip = fail_rec_array[array_index]
      port = fail_rec_array[array_index + 1].to_i
      array_index += 2
      
      #create the id-> this is why we had to lock the @to_id table
      id = get_id_by_ip(ip, port)
      
      #add the connection information and wait for the input thread to add in the
      # connection info since the server sending the failover will initiate all
      # communication
      @fail_rec[0][fail_index] = nil
      @fail_rec[1][fail_index] = ip
      @fail_rec[2][fail_index] = port
      @fail_rec[3][fail_index] = id
      @fail_rec[4][fail_index] = Time.now
      @fail_rec[5][fail_index] = true
      fail_index += 1
    end

    #now read in the fail_to data. This seems like a lot of the same code, but I
    # need it separate in case there is a differing number of elements
    fail_index = 0
    array_index = 0
    while fail_index <= (fail_to_array.length/ 2) do
      
      #get the ip and port from the input
      ip = fail_to_array[array_index]
      port = fail_to_array[array_index + 1].to_i
      array_index += 2
      
      #create the id-> this is why we had to lock the @to_id table
      id = get_id_by_ip(ip, port)
      
      #add the connection information and open a socket since as the server that
      # will be failing to these servers, the local server will initiate 
      # communication
      @fail_to[0][fail_index] = TCPSocket.new(ip, port)
      @fail_to[1][fail_index] = ip
      @fail_to[2][fail_index] = port
      @fail_to[3][fail_index] = id
      @fail_to[4][fail_index] = Time.now
      @fail_to[5][fail_index] = true
      fail_index += 1
    end
    
    failover.close
  end

  #threading functions: this functions are infinite loops that will also determine
  # when a failover is necessary
  
  #accept_thread: takes in the open TCPServer socket and accepts connections as they
  # come in 
  def accept_thread(server)
    #loop until the API is killed
    while !@@kill do
      #the accept statement will block until it receives a new connection-> that is
      # why this is a separate thread
      new_connect = server.accept()
      ip, port = new_connect.remote_address.ip_unpack
      
      #find out if there is already another connection, sending or receiving, with
      # this id and if so, then set that to the id
      assoc_index = "#{ip} #{port}"
      id = @to_id_table[assoc_index]
      #if there is not already an entry, then add the info into the table
      if id.nil? then
        id = @maxId
        @to_id_table[assoc_index] = id
        @maxId += 1
      #if there was not already an entry, see if we need to add this connection into
      # the fail_rec array
      else
        index = find_index_by_id(id, @fail_rec)
        #if there is an element in the @fail_rec array with the same id, then add
        # the connection into the 0th element if it is not already nil
        if !index.nil? && @fail_rec[0][index].nil? then
          @fail_rec[0][index] = new_connect
        end
      end
      
      #get a lock on @connects, then add stuff onto it
      index = @connects[0].length
      puts "just accepted #{ip} #{port} and put at index #{index}"
      #append the connection's information onto the end of @connects
      @connects[0][index] = new_connect
      @connects[1][index] =  ip
      @connects[2][index] =  port
      @connects[3][index] =  Time.now
      @connects[4][index] = @connects.length
      @connects[5][index] = true
      
      #now let another thread use the connections
    end
  end

  #input_thread: checks to be sure that input is still coming in. If there has
  # been no input in @failover_timeout seconds, then initiate a failover. If a
  # specific connections has not had any input in @failover_timeout seconds, then
  # failover that connection

  def input_thread
    #set up a timestamp to tell if we have been DDOSed
    overall_timestamp =  Time.now
    #loop until the API is killed- note using dc because I don't have any writes or
    # exception streams that I care about
    while !@@kill do
      #this is really inefficient in terms of memory copying, but I need to make sure
      # that @connects is not modified while I wait for IO and I will use
      # input_array many times

      #now get the length of the connection array
      length = @connects[0].length

      #now loop through every connection in the connection array and see if there
      # is any data to be received and if so, send the data to receive_data
      #Note: I am not just waiting on all the input because I want to ensure mutual
      # exclusion for the connections and I don't want other operations to have to
      # wait forever
      for index in 0...length do
        #acquire a lock on the connection
        
        #see if there is any input waiting and if so, then send it to receive_data
        input_arr = select([@connects[0][index]],nil,nil, 0)
        
        #this test is necessary to provide helpful data to the rest of my code
        if input_arr.nil?
          input = nil
        else
          input = input_arr[0].at(0)
        end
        #call receive_data if there is data waiting
        if !input.nil? then
          #reset the overall timestamp if data was received
          overall_timestamp =  Time.now
          #and the timestamp for just this connection
          @connects[3][index] = Time.now
          #if this connection was marked as dead, now mark it as alive
          @connects[5][index] = true

          #now receive the data and leave the connections unlocked until the next
          # loop
          self.receive_data(index)
        else
          #if a server has not sent anything in failover timeout seconds, then
          # check if the server is alive. If not, then send it a message and
          # mark it for followup
          #Note that input_array[5] is true if the connection is alive
          if @connects[5][index] && @connects[3][index] < (Time.now - @failover_timeout) then
            #send a message to the server to check its status. This will also add the
            # server to the status unsure list and have check_status perform further
            # logic on it
            self.send_alive(index)
          end
          #release the data to increase concurrency
        end
      end
      
      #now that we have gotten all the waiting input, see if any failover actions
      # need to be taken and check up on those connections on the status_unsure list
      self.check_status()

      #if there has not been any input in @failover_timeout seconds, then assume that 
      # the local server was DDOSed
      self.self_fail if ((Time.now - overall_timestamp) > @failover_timeout)
    end
  end    

  #backup_thread: use this function in a seperate thread to force a backup after
  # force_backup seconds
  def backup_thread
    #this thread does not need to run very often and I want to make sure it is not
    # frequently scheduled. Therefore, I am going to do a join on the input thread
    # for @force_backup seconds. Note that this join will never return anything 
    # other than nil because the input thread is in an infinite loop and is 
    # essentially a wait
    until @input_threadT.join(@force_backup) do
      backups_to_force = []
      #find any backups that are too old
      #acquire data lock
      @fail_to[0].each_index do |index|
        #if the backup is older than @force_backup seconds, then force a backup
        backups_to_force << index if @fail_to[3][index] < (Time.now - @force_backup)
      end
      #release lock on fail_to
      #force a backup for those that are too old
      data = @service_object.to_yaml
      backups_to_force.each do |backup|
        #acquire data
        #get the id and update the time stamp
        id = @fail_to[4][backup]
        @fail_to[3][backup] = Time.now
        #release data

        send_backup(backup, data)
      end
    end
  end

  #we are now done with threading functions so move onto other public methods
  
  #check_status(nil): examine the connections on the status_unsure list and if a
  # server has exceeded the time limit to respond to the send_alive call or the
  # send_alive call returns that the server is dead(designed to make testing easier)
  # then close the connection and delete it. 
  #Note: this server never marks servers as alive. That is done in the input thread
  # and proc_alive
  #fixMe-> refactor to provide more concurrency
  #fixMe-> refactor to contain failover_logic
  def check_status()
    #loop through every element in the status unsure array
    length = @status_unsure[0].length

    for index in 0...length do
      #for greater concurrency, unlock and relock the data on each loop

      #if time is expired, or the status of the connection has been set to dead,
      # then mark the connection as dead
      if @failover_timeout < (@status_unsure[3][index] - Time.now) || @status_unsure[5][index] == false then

        #if the connection is a failover connection and is being monitored, then
        # perform additional logic and initiate failover
        #if the local server is a hot failover for this remote server, then
        # fail it over and inform its dependent servers

        
        #don't need to acquire data because it is already locked
        address , port = @status_unsure[0][index], @status_unsure[2][index]
        id = @status_unsure[4][index]

        #if the local server is a hot failover for this server, then perform
        # additional logic to accept the failover from our end and notify the other
        # server
        #acquire lock on the @fail_to data
        if !find_index_by_ip(address, port, @fail_to).nil? then
          #release the data

          #tell the failed server that it is being failed over            
          #acquire data lock
          send_index = find_index_by_ip(address, port, @connects)
          send_id = @connects[4][send_index]
          #release the data
          send_fail(send_id, -1, send_id)

          #and inform all its dependent servers
          @dependents[0].each_index do |dep_index|
            dep_ip, dep_port = @dependents[1][dep_index], @dependents[2][dep_index]
            #either use an existing connection, or open a new one if the local
            # server is not communicating with it
            dep_index = find_index_by_ip(dep_ip, dep_port)
            if dep_index.nil? then send_fail(send_id, -1, dep_ip, dep_port)
            else send_fail(send_id, -1, dep_index)
            end
          end

          #now that everything else has been done, tell the local server to take over
          # for the failed server
          @service_object.rec_fail(@rec_backups[0][fail_index])

          mark_dead(id)
        #now for the case that the server is not a backup, just mark it as dead
        else
          #make sure that data is released
          
          #now mark the server as dead
          mark_dead(id)
        end
      end
      #unlock the data for greater concurrency before we loop through again

    end
    return true
  end

  #send_data(int input, *proc_data): this function will send proc_data to the given 
  # connection. if the address and port_num do not map to an id, such as when they
  # have not been created yet, then a new connection will be created for them. 
  # Since method overloading has to be done inside the class, then I will just test
  # if input is an integer, meaning that it is an id or else I will assume it is an
  # ip address and will create a new socket for the ip and port
  def send_data(input, *proc_data)
    #if input is an integer, then use it as an id, otherwise it is an ip address
    if input.is_a? Integer then
      id = input
      data = proc_data
      connect_index = find_index_by_id(id, @connects)
    #create a new connection using the first input as an ip address and the second
    # input as a port number. The rest is still data to send
    else
      #acquire locks on the to_id and connection lists
      connect_index, id = create_connect(input, proc_data.delete_at(0))
      #release locks on the to_id and connection lists
    end
    
    #send the data and test if the server has been killed. If the server is dead,
    # then don't send anything
    #if this server has been "killed", then don't send anything
    return nil if @@kill

    #now just send the data with a terminating character
    #acquire data lock
    @connects[0][connect_index].puts proc_data
    @connects[0][connect_index].puts "|::|"
    #release lock

    #and finally return the connection id
    return id
  end

  #receive_data: will receive data from a server and pass it to the get_data method
  # of the service object
  def receive_data(index)
    #if this server has been "killed", then dont accept any more connections
    return nil if @@kill
    
    #read in the first 5 characters to determine where to go from here and then 
    # read in the rest of the data up to the next seperator, |:
    #acquire data lock
    meth_sel =  @connects[0][index].read(5)
    data = @connects[0][index].gets("|::|")
    
    #release lock
    #remove white space from meth_sel and the data seperator, |::|, from the data
    data.chomp!("|::|")

    #use a case statement to determine what method to call
    case meth_sel
    when "kill "
      self.kill
    when "back "
      receive_backup(index, data)
    when "fail "
      proc_fail(index, data)
    when "alive"
      proc_alive(index, data)
    else
      #otherwise, give the data to the service by handing it to the get_data method
      rec_data = meth_sel << data
      @service_object.get_data(rec_data, index)
    end

  end

  #send_backup(nil) or
  #send_backup(int id, *backup_data) or 
  #send_backup(int id) or
  #send_backup(string ip, int port, *backup_data) or
  #send_backup(string ip, int port): will send the backup data from 
  # the service to the given connection by marshalling the service object using yaml
  #Note: this function is overloaded and will pick the right method to use. If an id
  # is used, then the connection is assumed to exist. If an ip and port are used, 
  # then it is assumed that the connection does not exist and a new connection will
  # be created. If there are no arguments, then a backup is created with the service
  # object's to_yaml method and sent to all the servers it could fail over to.
  # Backup_data may also be set to nil, and in that case, the backup will be generated
  # from the service object's to_yaml method.
  #This method will return 1 for success, 0 for failure
  def send_backup(input)
    #use some logic to determine which method we are calling

    #send_backup(nil): send a backup to every connection that we could fail over to
    # and create backup_data from the service object's to_yaml method
    if input[0].nil? then
      backup_data = @service_object.to_yaml
      @fail_to[0].each_index do |back_index|
        # @fail_to_sem.lock
        send_backup(back_index, backup_data)
        # @fail_to_sem.unlock
      end
      return 1;

    #send_backup(int id) and
    #send_backup(int id, *backup_data): send a backup to the connection with the 
    # given id and create backup_dat from the service object's to_yaml method
    elsif input[0].is_a? Integer then
      #I am deleting the id from the input as I assign it to reduce steps later if
      # there is backup data given as well
      id = input.delete_at(0)
      
    #send_backup(string ip, int port) and
    #send_backup(string ip, int port, *backup_data): create a new connection for
    # the given ip and port and send the backup data on that socket. If not specified
    # by the user, then get the backup data from the service object's to_yaml method
    elsif input[0].is_a? String and input[1].is_a? Integer then
      #as above, I am deleting the ip address and port from the input as I process 
      # to save steps
      ip = input.delete_at(0)
      port = input.delete_at(0)

      #create the connection
      #acquire locks on the connection and to_id lists
      index, id = create_connect(ip, port)      
      #release locks on the connections and to_id lists

    #otherwise, it is an invalid call so tell the user and raise and exception
    else
      puts "Invalid call to send_backup: #{input}"
      raise
    end

    #if only the connection info was given, meaning the next element is nil, then
    # get the backup data from the service object's to_yaml method and use the
    # given data otherwise
    if input[0].nil? then
      backup_data = input
      #no data given, so get backup data from the service object's to_yaml method
    else
      backup_data = @service_object.to_yaml
    end
    
    #add the keyword backup, then a timestamp for the current time, and send it
    data_to_send = "backup #{Time.now}|: "
    data_to_send << backup_data
    send_data(id, data_to_send)

    #now return 1 for success
    return 1
  end

  #receive_backup(id, backup_data): will receive a backup from a 
  # process and compare it to existing backups. If it is newer, it will replace the
  # older backup and if not, it will keep the old backup. This function returns 0
  # for error, 1 if it used this backup, and 2 if it used the old backup
  def receive_backup(index, backup_data)
    #split the data into the actual data and its timestamp
    time, backup_data = backup_data.split("|: ")
    id = @connects[4][index]

    #if the backup connection does not exist yet, then create it
    if @rec_backups[3][id].nil? then
      ip, port = @connects[1][index], @connects[2][index]
      @rec_backups[3][id] = time
      @rec_backups[0][index] = backup_data
      return 1
    #if the backup connnection does exist and this backup is newer, then use it
    elsif(@rec_backups[3][index] < time) then
      @rec_backups[3][index] = time
      @rec_backups[0][index] = backup_data

      #release backup data
      return 1
    else
      # release backup data
    end
    
    #otherwise, just return 2 to indicate that the old backup was newer
    return 2
  end

  #self_fail(nil): this function will fail the local server over after it has been 
  # DDOSed. In a realistic scenario, this function would not be able to do anything
  #fixMe-> finish writing
  def self_fail
    #tell the failover server that it will be receiving data
    #acquire data lock on connects
    send_index = find_index_by_ip(@failover_connects[1], @failover_connects[2], @connects)
    send_id = @connects[4][send_index]
    #release connects
    send_fail(-1, send_id, send_id)
    
    #and inform all our dependent servers
    #acquire data lock on the dependent list
    @dependents[0].each_index do |dep_index|
      dep_ip, dep_port = @dependents[1][dep_index], @dependents[2][dep_index]

      #either use an existing connection, or open a new one if the local
      # server is not communicating with it
      dep_index = find_index_by_ip(dep_ip, dep_port)
      dep_index = create_connect(dep_ip, dep_port) if dep_index.nil?
      send_fail(-1, send_id, dep_index)
    end
    #release lock on the dependent list

    #now set our status to dead
    @alive = false
  end

  #send_fail(fail_from, fail_to, rec_serv): this function will instruct the 
  # recepient server, dest_serv, to begin using fail_to instead of fail_to.
  #Note: a reference of -1 is a reference to self and each of these connections is
  # referenced by id number
  def send_fail(fail_from, fail_to, rec_serv)
    #if fail_from is set to -1, then it is a reference to the local server and use
    # that data
    if(fail_from == -1) then
      fail_from_ip, fail_from_port = @local_ip, @local_port      
    else
      #acquire data and find the data from the receiving connection
      fail_from_index = find_index_by_id(fail_from, @connects)
      fail_from_ip = @connects[1][fail_from_index]
      fail_from_port = @connects[2][fail_from_index]
      #release the connection data
    end
    
    #now find the data for the destination of the failover from fail_to and if it is
    # set to -1, then use the local server's info
    if(fail_to == -1) then
      fail_to_ip, fail_to_port = @local_ip, @local_port      
    else
      #acquire data and find the data from the receiving connection
      fail_to_index = find_index_by_id(fail_to, @connects)
      fail_to_ip = @connects[1][fail_to_index]
      fail_to_port = @connects[2][fail_to_index]
     #release the connection data
    end
    
    #now find the connection to send the message to-> note that we are not checking
    # the case that rec_serv is -1 because it would not make sense to send this to
    # ourselves and any cases that require it would be better left to create a new
    # function for the data manipulation if we did want to send this to the local
    # server
    #acquire connnection data
    dest_connect = find_index_by_id(dest_serv, @connects)
    #release data
   
    #create the data to send
    data_to_send = "fail #{fail_from_ip} #{fail_from_port} #{fail_to_ip} #{fail_to_port}"
    #and send the data-> be sure to create a connection if a connection does not
    # already exist
    if dest_connect.nil? then
      #find the ip and port to send the data to
     # @conn_sem.lock
      index = find_index_by_id(dest_serv, @connects)
      ip, port = @connects[1][index], @connects[2][index]
     # @conn_sem.unlock
      send_data(ip, port, data_to_send)
    else
      send_data(dest_connect, data_to_send)
    end
  end

  #proc_fail(int index, string request): will process an incoming failover request 
  # and determine what actions to take. Note that the API and this function do not
  # care if we are relient upon this server-> if a server that we are dependent upon
  # is being failed over, then we will adjust. 
  # This method will return 1 if it was successful in removing the connection and
  # return 0 if the connection did not exist or there was an error
  # fail_from is who is dying, fail_to is who is taking over
  def proc_fail(index, request)
    #start by parsing the ip and port info from the data
    fail_from_ip, fail_from_port, fail_to_ip, fail_to_port = request.split(" ")
    
    #check if this request has already been processed. If the server is in dead
    # connects(it was a hot failover or we are dependent upon it) or it is not in
    # connects(closed and killed connection), then return
    #lock the dead connections list
    dead = find_index_by_ip(fail_from_ip, fail_from_port, @dead_connects)
    #release the dead connections lock
    #return if the index is not nil, aka it was in dead connects
    return 0 if !index.nil?
    
    #now find out if we are set to receive failovers from this server
    #lock the list of failover connections to receive
    fail_index = find_index_by_ip(fail_from_ip, fail_from_port, @fail_rec)
    #unlock the list

    #if the fail_from ip and port are the same as the local server, then initiate a
    # self_fail because the local server has been ddosed
    if(fail_from_ip == @local_ip && fail_from_port == @local_port) then
      self.self_fail

    #if the fail_to ip and port are the same as the local server, then notify all
    # dependents because the local server is taking over-> I am assuming that this
    # is only called when the local server is actually set up as a hot failover for
    # the server
    elsif !fail_index.nil? then
      #close and delete the connection, but save the id
      #lock the connection list
      id = @connects[4][index]
      @connects[0][index].close
      delete_elem(index, @connects)
      #release the lock on the connection list
      
      #now remove the connection from the failover_rec list and add the
      #connection to the dead list
      #lock the list of servers we will accept failovers from
      delete_elem(id, @fail_rec)
      #unlock the list
      
      #add the connection to the dead list
      #lock the list of dead connection
      dead_index = @dead_connects.length
      @dead_connects[0][dead_index] = nil 
      @dead_connects[1][dead_index] = fail_from_ip
      @dead_connects[2][dead_index] = fail_from_port 
      @dead_connects[3][dead_index] = Time.now
      @dead_connects[4][dead_index] = id
      @dead_connects[5][dead_index] = false
      #and unlock the list of dead connections
      
      #and notify my dependents that I am taking over
      @dependents[0].each_index do |dep_index|
        dep_ip, dep_port = @dependents[1][dep_index], @dependents[2][dep_index]
        #either use an existing connection, or open a new one if the local
        # server is not communicating with it
        dep_index = find_index_by_ip(dep_ip, dep_port)
        if dep_index.nil? then send_fail(send_id, -1, dep_ip, dep_port)
        else send_fail(send_id, -1, dep_index)
        end
      end
      
      #lastly, tell our service object to take over for the other server by calling
      # the rec_fail function on the service object with the latest backup for it
      @service_object.rec_fail(@rec_backups[0][fail_index])
    
    #if this server is not a hot failover, then close the old connection
    # and copy the new connection info into the old slot. Also, if there is an open
    # connection, then replace all entries in check_status and connects with the id
    # of the failed process-> basically, assuming that server will only send data or
    # be a backup, not both because the old id will be erased. I will make this
    # better in future implementations
    else
      #close the old connection, but store the value of the id and update the server
      # referenced by fail_to with this new id-> will update status_unsure and 
      # receive backups along with connects, so I will have to acquire the locks 
      # here to be sure that all data is up to date when the lists are accessed
      
      #now close the connection and delete its data
      mark_dead(@fail_from_ip, @fail_from_port)

      #lock the list of connections that have unsure statuses
      #lock the list of received backups
      #lock the list of connections
      #close and delete the old connection, but save the id
      new_id = @connects[4][index]
      new_index = find_index_by_ip(@fail_from_ip, @fail_from_port, @connects)
      @connects[4][new_index] = new_id

      #update the id of the failover connection in connects
      new_index = find_index_by_ip(@fail_from_ip, @fail_from_port, @connects)
      @connects[4][new_index] = new_id
      #unlock the list of connections
     
      #update the rec_backups
      new_index = find_index_by_ip(@fail_from_ip, @fail_from_port, @rec_backups)
      @rec_backups[4][new_index] = new_id
      #unlock the list of received backups

      #update the status_unsure list
      new_index = find_index_by_ip(@fail_from_ip, @fail_from_port, @status_unsure)
      @status_unsure[4][new_index] = new_id
      #unlock the list of unsure statuses
    end
  end


  #send_alive: will send a check alive message to a remote server to see if it is
  # still alive
  def send_alive(index)
    #get the id for the given index
    #acquire lock on the connection list
    connection = @connects[0][index]
    ip  = @connects[1][index]
    port = @connects[2][index]
    id = @connects[4][index]
    #release lock on the connection list

    #now add the connection to the status unsure list if it is not already on it
    #lock access to the status unsure list
    on_list = find_index_by_id(id, @status_unsure)
    #if the connection is not already on the list, then add it
    if on_list.nil? then
      stat_index = @status_unsure[0].length
      @status_unsure[0][stat_index] = connection
      @status_unsure[1][stat_index] = ip
      @status_unsure[2][stat_index] = port
      @status_unsure[3][stat_index] = Time.now
      @status_unsure[4][stat_index] = id
      @status_unsure[5][stat_index] = true      
    end
    #release the lock on the status unsure list

    #create a message to send to the other server
    data_to_send = "alive send #{@local_ip} #{@local_port}"
    #finally, send a simple alive command
    send_data(index, data_to_send)
  end
  
  #proc_alive: will process an incoming check_alive request and adjust accordingly
  # the data structures to reflect the receipt of new input
  def proc_alive(id, data)
    #set the value of alive 
    if !@@kill && @alive then
      alive = true
    else
      alive = false
    end

    #split the data into a selector, hostname, and port based on a space 
    selector, ip, port, rest = data.split(" ")
    
    #determine whether we are sending our status or receiving info about another
    # servers status
    case selector
    when "send"
      if(alive) then
        data_to_send = "alive ret #{ip} #{port} #{alive}"
        #see if there is already a connection and pick send_data method accordingly
        #lock the connection list
        connection = find_index_by_ip(ip, port, @connects)
        #release the lock on the connection list
        #if there is not a connection already, have send_data create one
        if connection.nil? then send_data(ip, port, data_to_send)
        else send_data(connection, data_to_send)
        end
      end
    when "ret"
      #begin by setting the status of all these connections to alive
      #find the id
      #lock the connection list
      index = find_index_by_ip(ip, port, @connects)
      id = @connects[4][index]
      connects = find_all_by_id(id, @connects)
      #and update these connections
      connects.each do |index|
        @connects[3][index] = Time.now
        @connects[5][index] = true
      end
      #release the lock on the connection list

      #now move onto removing connections from @status_unsure
      #lock access to the status unsure list
      @status_unsure.each_index do |index|
        #if the id is the same, then remove it from @status_unsure
        delete_elem(index, @status_unsure) if @status_unsure[4][index] == id
      end
      #release the lock on the status unsure list
    #print an error when there is an unexpected case
    else
      puts "\nError in proc_alive: Invalid processing option\n"
    end
  end

  #kill: if the API needs to be killed, this method keeps the API from continuously
  # failing over to new servers
  #Note: this is a class instance variable
  def kill
    @@kill = true
  end

  def unkill
    @@kill = false
  end

  #helper functions that must be private
  #fixMe-> for unit testing I am setting all of the private methods to public
  #private
  attr_accessor :connects, :kill, :alive, :fail_to


  #fixMe-> finish writing-> already hav logic in code for this, this would just make
  # life easier
  #accept_fail(string address, int port): this method will accept a failover from a
  # server. It will simplify the code and make maintainence easier to have this in
  # one place. The function will fail the server over from the server at address
  # and port to the local server
  def accept_fail(address, port)
    #tell the failed server that it is being failed over            
    #acquire data lock on the connection list
    send_index = find_index_by_ip(address, port, @connects)
    send_id = @connects[4][send_index]
    #release the lock on the connection list
    send_fail(send_id, -1, send_id)
    
    #and inform all its dependent servers
    #lock access to the dependent list
    @dependents[0].each_index do |dep_index|
      dep_ip, dep_port = @dependents[1][dep_index], @dependents[2][dep_index]
      #either use an existing connection, or open a new one if the local
      # server is not communicating with it
      dep_index = find_index_by_ip(dep_ip, dep_port)
      if dep_index.nil? then send_fail(send_id, -1, dep_ip, dep_port)
      else send_fail(send_id, -1, dep_index)
      end
    end
    #release the lock on the dependent list
    
    #now that everything else has been done, tell the local server to take over
    # for the failed server
    @service_object.rec_fail(@rec_backups[0][fail_index])
    
    mark_dead(id)
  end



  #create_connect(string address, int port): this function will create a new
  # connection on the @connects list and return its index
  #Note: before calling this function you must acquire a lock on the to_id list and
  # the connection list. 
  def create_connect(address, port)
    index = @connects[0].length
    @connects[0][index] = TCPSocket.new(address, port)
    @connects[1][index] = address
    @connects[2][index] = port
    @connects[3][index] = Time.now
    @maxId = @maxId + 1
    id = @connects[4][index] = get_id_by_ip(address, port)
    @connects[5][index] = true
    return [index, id]
  end

  #mark_dead(string ip, int port): will mark all connections with the given 
  # id as dead and close the connections. Though this implementation won't use it, 
  # I am also adding the connection info to a list of dead connections. 
  #Note: this method will delete connections on the @connects, @dependents,
  # @status_unsure, and @fail_from
  #fixMe-> finish writing and deal with dependent servers-> concurrently lock all
  # the lists or just dont care that they will not all be synchronized? Is
  # synchronization worth the performance increase
  def mark_dead(ip, port)
    #start by getting the connection's info from @connects
    #lock access to connects
    index = find_index_by_id(id, @connects)
    ip, port = @connects[1][index], @connects[2][index]
    #release lock on connects

    #get and delete all connections with the given ip
    #lock the connection list
    connects = find_all_by_ip(ip, port, @connects)
    #now close and delete each connection in the @connects list
    connects.each_index do |index|
      #close the connection
      @connects[0][index].close
      #and delete it
      delete_elem(index, @connects)
    end
    #release the connection list

    #now do the same list of connections dependent upon us
    #lock the dependents list
    connects = find_all_by_ip(ip, port, @dependents)
    #now delete and close each connection
    connects.each_index do |index|
      #delete all the data
      delete_elem(index, @dependents)
    end
    #release the dependents list

    #delete the connection data from the send and receive backups list
    # if the list is on the fail_to list, and is therefore a failover, then
    # add it to the dead connects list
    #lock the dead connections list
    #lock the fail_to list
    indices = find_all_by_ip(ip, port, @fail_to)
    indices.each do |index|
      #remove the backup
      delete_elem(index, @fail_to)
    end
    #release lock on the fail_to list

    #if the connection was on the @fail_to list, then add it to the dead list
    # because it is one of our failovers
    if !indices.empty? then
      #add the connection to the @dead_connects list using the standard notation even
      # though the 0th element in dead_connects will be nil because there is not an
      # associated connection
      dead_index = @dead_connects.length 
      @dead_connects[0][dead_index] = nil
      @dead_connects[1][dead_index] = ip
      @dead_connects[2][dead_index] = port
      @dead_connects[3][dead_index] = Time.now
      @dead_connects[4][dead_index] = id
      @dead_connects[5][dead_index] = false
    end
    #release lock on the dead connections list

    #find connections to remove on @status_unsure
    #lock the status unsure list
    indices = find_all_by_ip(ip, port, @status_unsure)
    indices.each do |index|
      delete_elem(index, @status_unsure)
    end
  end
  
  #delete_elem(int index, reference * list): will delete the connection with the
  # given index on the list. This function will not close the connection however.
  # Will return 0 for failure, 1 for success.
  def delete_elem(index, list)
    #delete all the data
    list[0].delete_at(index)
    list[1].delete_at(index)
    list[2].delete_at(index)
    list[3].delete_at(index)
    list[4].delete_at(index)
    list[5].delete_at(index)
    return 1
  end


  #change_serv: will close the connection to source_serv and replace its entries in
  # connects with dest_serv. If there is not an open connection
  # to dest_serv, it will open it before replacing the references
  def change_serv(source_serv, dest_serv)
  end

  #find_index_by_ip: will find the connection to the socket given by address and 
  # port in the connection list given by list. If it is not found, the method will 
  # return nil
  def find_index_by_ip(address, port, list)
    list.each_index do |index|
      return index if address == list[1][index] && port == list[2][index]
    end
    #if the address hasn't been found, return nil
    return nil
  end

  #find_all_by_ip(string address, int port, reference * list): will find all 
  # connections that match the given address and port and return their indices in an
  # array.
  def find_all_by_ip(address, port, list)
    index_array = []
    list.each_index do |index|
      index_array << index if ip == list[1][index] && port == list[2][index]
    end
  end


  #find_index_by_id: will find the connection to the socket given by address and 
  # port in the connection list given by list. If it is not found, the method will
  # return nil
  def find_index_by_id(id, list)
    found_index = nil
    list[4].each_index do |index|
      if list[4][index] == id then
        found_index = index
        break;
      end
    end
    return found_index    
  end
    
  #find_all_by_id(int id, reference * list): will return all connections in the given
  # list with the given id
  def find_all_by_id(id, list)
    connects = []
    list[4].each_index do |index|
      if list[4][index] == id then
        connects << index
      end
    end
  end
  
  #find_ip_by_id(int id): this method will return the ip and port associated with
  # the given id as an array, [ip, id], eg ['localhost', 80] and will return nil
  # if there is not an ip and port associated with the given id
  def find_ip_by_id(id)
    @to_ip_table[id]
  end

  #find_id_by_ip(string ip, int port): this method is very similar to get_id_by_ip,
  # but this method will return nil if there is not an id associated with the
  # address and port and get_id_by_ip will create a new id
  def find_id_by_ip(*args)
    if args.length == 1
      assoc_index = "self"
    else
      assoc_index = "#{args[0]} #{args[1]}"
    end
    #now combine the ip and port into one string
    id = @to_id_table[assoc_index]
  end    

  #get_id_by_ip(string ip, int port): this method will lookup the id to return to
  # the service based upon the ip-> just have all ips that are failovers for each
  # other return the same id-> use an associative array
  def get_id_by_ip(ip, port)
    #now combine the ip and port into one string
    assoc_index = "#{ip} #{port}"
    id = @to_id_table[assoc_index]
    #if there is not already an entry, then add the info into the table
    if id.nil? then
      id = @maxId
      @to_id_table[assoc_index] = id
      @to_ip_table[id] = [ip, port]
      @maxId += 1
    end
    
    #and return it
    return id
  end

  #heres a few debugging functions
  def check_connect_alive(ip, port)
    index = find_index_by_ip(ip, port, @connects)
    if !index.nil?
      return @connects[5][index]
    else
      return false
    end
  end

  def still_alive
    if @@kill == false and @alive == true then
      return true
    else
      return false
    end
  end    
 public :still_alive, :check_connect_alive

end

