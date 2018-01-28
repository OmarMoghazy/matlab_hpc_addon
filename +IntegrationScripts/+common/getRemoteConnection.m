function remoteConnection = getRemoteConnection(cluster, clusterHost, remoteJobStorageLocation, makeLocationUnique)
%GETREMOTECONNECTION Get a connected RemoteClusterAccess
%
% getRemoteConnection will either retrieve a RemoteClusterAccess from the
% cluster's UserData or it will create a new RemoteClusterAccess.
%

% Copyright 2010-2017 The MathWorks, Inc.

% Store the current filename for the dctSchedulerMessages
currFilename = mfilename;

if ~ischar(clusterHost)
    error('parallelexamples:GenericSLURM:IncorrectArguments', ...
          'Hostname must be a string');
end
if ~ischar(remoteJobStorageLocation)
    error('parallelexamples:GenericSLURM:RemoteJobStorageLocationType', ...
          'Remote Job Storage Location must be a character vector');
end

needToCreateNewConnection = false;
if isempty(cluster.UserData)
    needToCreateNewConnection = true;
else
    if ~isstruct(cluster.UserData)
        error('parallelexamples:GenericSLURM:IncorrectUserData', ...
              ['Failed to retrieve remote connection from cluster''s UserData.\n' ...
              'Expected cluster''s UserData to be a structure, but found %s'], ...
              class(cluster.UserData));
    end

    if isfield(cluster.UserData, 'RemoteConnection')
        % Get the remote connection out of the cluster user data
        remoteConnection = cluster.UserData.RemoteConnection;

        % And check it is of the type that we expect
        if isempty(remoteConnection)
            needToCreateNewConnection = true;
        else
            clusterAccessClassname = 'parallel.cluster.RemoteClusterAccess';
            if ~isa(remoteConnection, clusterAccessClassname)
                error('parallelexamples:GenericSLURM:IncorrectArguments', ...
                      ['Failed to retrieve remote connection from cluster''s UserData.\n' ...
                      'Expected the RemoteConnection field of the UserData to contain an object of type %s, but found %s.'], ...
                      clusterAccessClassname, class(remoteConnection));
            end

            if makeLocationUnique
                username = remoteConnection.Username;
                expectedRemoteJobStorageLocation = iBuildUniqueSubfolder(remoteJobStorageLocation, username, iGetFileSeparator(cluster));
            else
                expectedRemoteJobStorageLocation = remoteJobStorageLocation;
            end

            if ~remoteConnection.IsConnected
                needToCreateNewConnection = true;
            elseif ~(strcmpi(remoteConnection.Hostname, clusterHost) && ...
                     remoteConnection.IsFileMirrorSupported && ...
                     strcmpi(remoteConnection.JobStorageLocation, expectedRemoteJobStorageLocation))
                % The connection stored in the user data does not match the cluster host
                % and remote location requested
                warning('parallelexamples:GenericSLURM:DifferentRemoteParameters', ...
                        ['The current cluster is already using cluster host %s and remote job storage location %s.\n', ...
                        'The existing connection to %s will be replaced.'], ...
                        remoteConnection.Hostname, remoteConnection.JobStorageLocation, remoteConnection.Hostname);
                cluster.UserData.RemoteConnection = [];
                needToCreateNewConnection = true;
            end
        end
    else
        needToCreateNewConnection = true;
    end
end

if ~needToCreateNewConnection
    return;
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% CUSTOMIZATION MAY BE REQUIRED %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Get the credential options from the user using simple
% MATLAB dialogs or command line input.  You should change
% this section if you wish for users to provide their credential
% options in a different way.
% The pertinent options are:
% username - the username to use when running commands on the remote host
% useIdentityFile - whether or not to use an identity file (true/false).
%                   False means that a password is used
% identityFilename - the full path to the identity file
% fileHasPassphrase - whether or not the identity file requires a passphrase
%                     (true/false).
if isempty(javachk('awt'))
    % MATLAB has been started with a desktop, so use dialogs to get credential data.
    [username, useIdentityFile, identityFilename, fileHasPassphrase] = iGetCredentialsFromUI(clusterHost, cluster);
else
    % MATLAB has been started in nodisplay mode, so use command line to get credential data
    [username, useIdentityFile, identityFilename, fileHasPassphrase] = iGetCredentialsFromCommandLine(clusterHost, cluster);
end

% Establish a new connection
parameterMap = getOrCreateCredentialsParameterMapWithPort(clusterHost, cluster, username, useIdentityFile, identityFilename, fileHasPassphrase);
if useIdentityFile
    dctSchedulerMessage(1, '%s: Identity file %s will be used for remote connections', currFilename, username, identityFilename);
end
userArgs = {username, 'PCTQECredentialMap', parameterMap};

% Now connect and store the connection
dctSchedulerMessage(1, '%s: Connecting to remote host %s', currFilename, clusterHost);
remoteConnection = parallel.cluster.RemoteClusterAccess.getConnectedAccessWithMirror(clusterHost, remoteJobStorageLocation, userArgs{:});
dctSchedulerMessage(5, '%s: Storing remote connection in cluster''s user data.', currFilename);
cluster.UserData.RemoteConnection = remoteConnection;


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [username, useIdentityFile, identityFilename, fileHasPassphrase] = iGetCredentialsFromUI(clusterHost, cluster)
% Function to get the user credentials using dialogs
identityFilename = '';
fileHasPassphrase = false;

dlgTitle = 'User Credentials';
username = validatedPropValue(cluster, 'UserNameOnCluster', 'char');
if isempty(username)
    numlines = 1;
    dlgMessage = sprintf('Enter the username for %s', clusterHost);
    usernameResponse = inputdlg(dlgMessage, dlgTitle, numlines);
    % Hitting cancel gives an empty cell array, but a user providing an empty string gives
    % a (non-empty) cell array containing an empty string
    if isempty(usernameResponse)
        % User hit cancel
        error('parallelexamples:GenericSLURM:UserCancelledOperation', 'User cancelled operation.');
    end
    username = char(usernameResponse);
    cluster.AdditionalProperties.UserNameOnCluster = username;
    cluster.saveProfile
end

useIdentityFile = validatedPropValue(cluster, 'UseIdentityFile', 'bool', true);
if useIdentityFile==true
    identityFilename = validatedPropValue(cluster, 'IdentityFile', 'char');
    if isempty(identityFilename)
        dlgMessage = sprintf('Use an identity file to login to %s?', clusterHost);
        identityFileResponse = questdlg(dlgMessage, dlgTitle);
        if strcmp(identityFileResponse, 'Cancel')
            % User hit cancel
            error('parallelexamples:GenericSLURM:UserCancelledOperation', 'User cancelled operation.');
        end

        useIdentityFile = strcmp(identityFileResponse, 'Yes');
        cluster.AdditionalProperties.UseIdentityFile = useIdentityFile;
        cluster.saveProfile

        if ~useIdentityFile
            return
        end

        dlgMessage = 'Select Identity File to use';
        [filename, pathname] = uigetfile({'*.*', 'All Files (*.*)'},  dlgMessage);
        % If the user hit cancel, then filename and pathname will both be 0.
        if isequal(filename, 0) && isequal(pathname,0)
            error('parallelexamples:GenericSLURM:UserCancelledOperation', 'User cancelled operation.');
        end

        identityFilename = fullfile(pathname, filename);
        cluster.AdditionalProperties.IdentityFile = identityFilename;
        cluster.saveProfile
    end

    fileHasPassphrase = validatedPropValue(cluster, 'IdentityFileHasPassphrase', 'bool', false);

end


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [username, useIdentityFile, identityFilename, fileHasPassphrase] = iGetCredentialsFromCommandLine(clusterHost, cluster)
% Function to get the user credentials from the command line
identityFilename = '';
fileHasPassphrase = false;
validYesNoResponse = {'y', 'n'};

username = validatedPropValue(cluster, 'UserNameOnCluster', 'char');
if isempty(username)
    % Allow the username to be empty
    username = input(sprintf('Enter the username for %s:\n', clusterHost), 's');
    cluster.AdditionalProperties.UserNameOnCluster = username;
    cluster.saveProfile
end

useIdentityFile = validatedPropValue(cluster, 'UseIdentityFile', 'bool', true);
if useIdentityFile==true
    identityFilename = validatedPropValue(cluster, 'IdentityFile', 'char');
    if isempty(identityFilename)
        identityFileMessage = sprintf('Use an identity file to login to %s? (y or n)\n', clusterHost);
        identityFileResponse = iLoopUntilValidStringInput(identityFileMessage, validYesNoResponse);
        useIdentityFile = strcmpi(identityFileResponse, 'y');
        cluster.AdditionalProperties.UseIdentityFile = useIdentityFile;
        cluster.saveProfile

        if ~useIdentityFile
            return
        end

        while isempty(identityFilename)
            identityFilename = input(sprintf('Please enter the full path to the Identity File to use:\n'), 's');
        end
        cluster.AdditionalProperties.IdentityFile = identityFilename;
        cluster.saveProfile
    end

    fileHasPassphrase = validatedPropValue(cluster, 'FileHasPassphrase', 'bool');

end


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function returnValue = iLoopUntilValidStringInput(message, validValues)
%Function to loop until a valid response is obtained user input
returnValue = '';

while isempty(returnValue) || ~any(strcmpi(returnValue, validValues))
    returnValue = input(message, 's');
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function subfolder = iBuildUniqueSubfolder(remoteJobStorageLocation, username, fileSeparator)
%Function to build unique location using username and MATLAB release version
release = ['R' version('-release')];
subfolder = [remoteJobStorageLocation fileSeparator username fileSeparator release];

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function fileSeparator = iGetFileSeparator(cluster)
%Function to return file separator for cluster operating system
if strcmpi(cluster.OperatingSystem, 'unix')
    fileSeparator = '/';
else
    fileSeparator = '\';
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function credentials = getOrCreateCredentialsParameterMapWithPort(combinedHostname, cluster, username, useIdentityFile, identityFilename, fileHasPassphrase)
import com.mathworks.toolbox.distcomp.clusteraccess.*;
import com.mathworks.toolbox.distcomp.remote.*;
import com.mathworks.toolbox.distcomp.remote.spi.plugin.SshParameter;
[hostname, portStr] = strsplit(combinedHostname, ':');
% We've modified ClusterInfo to add an SshPort value, so we'll use that
% default port=22;
port = validatedPropValue(cluster, 'SshPort', 'double');
if ischar(portStr)
    portNum = str2num(portStr); %#ok<ST2NM>
    if isnumeric(portNum) && portNum > 0
        port = uint32(portNum);
    end
else
    port = uint32(port);
end
hostname = hostname{:};

dctSchedulerMessage(6, 'Using username %s to connect to %s on port %d', username, hostname, port);

% Do an explicit conversion of the username to a java string because
% something goes wrong with the char->string conversion when the MATLAB
% char has only 1 character.
javaUsername = java.lang.String(username);

credentials = ParameterMap();
credentials.put(SshParameter.STRICT_HOST_KEY_CHECKING, SshParameter.STRICT_HOST_KEY_CHECKING.getSuggestedValue());
credentials.put(SshParameter.PORT, port);
credentialParameters = ParameterMap();

if useIdentityFile
    keyFile= java.io.File(identityFilename);
    credentialParameters.put(IdentityFileCredentialDescription.USERNAME, javaUsername);
    credentialParameters.put(IdentityFileCredentialDescription.IDENTITY_FILE, keyFile);
    if fileHasPassphrase
        passphraseMsg = getString(message('parallel:cluster:EnterPassphraseForIdentityFile', identityFilename));
        keyfilePassPhrase = solicitPassword(passphraseMsg);
        credentialParameters.put(IdentityFileCredentialDescription.PASSPHRASE, keyfilePassPhrase);
    end
    credentials.put(SshParameter.SSH_CREDENTIAL, IdentityFileCredentialDescription.INSTANCE.create(credentialParameters));
else
    passwordMsg = getString(message('parallel:cluster:EnterPasswordForUserOnMachine', username, hostname));
    password = solicitPassword(passwordMsg);
    credentialParameters.put(PasswordCredentialDescription.USERNAME, javaUsername);
    credentialParameters.put(PasswordCredentialDescription.PASSWORD, password);
    credentials.put(SshParameter.SSH_CREDENTIAL, PasswordCredentialDescription.INSTANCE.create(credentialParameters));
end

function password = solicitPassword(promptMsg)
if com.mathworks.jmi.Support.useSwing()
    passwordField = javaObjectEDT('javax.swing.JPasswordField',40);
    result = javaMethodEDT('showConfirmDialog','javax.swing.JOptionPane', ...
                           [], passwordField, promptMsg, ...
                           javax.swing.JOptionPane.OK_CANCEL_OPTION, ...
                           javax.swing.JOptionPane.PLAIN_MESSAGE);
    if result == javax.swing.JOptionPane.OK_OPTION
        passwordString =  java.lang.String(passwordField.getPassword());
    else
        error(message('parallel:cluster:RemoteClusterAccessNoPassword'));
    end
else
    passwordChars = parallel.internal.readPassword(promptMsg);
    %if passwordChars is a java.lang.Exception then error
    if isa(passwordChars, 'java.lang.Exception')
        msg = char(passwordChars.getMessage());
        error(message('parallel:cluster:RemoteClusterAccessProblemGettingPassword', msg));
    end
    passwordString = java.lang.String(passwordChars);
end

password = com.mathworks.toolbox.distcomp.remote.Password(passwordString);
