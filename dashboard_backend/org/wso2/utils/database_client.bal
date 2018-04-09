// Copyright (c) 2018 WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License atdeshanigtk
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied. See the License for the
// specific language governing permissions and limitations
// under the License.

package org.wso2.utils;

import ballerina.data.sql;
import ballerina.time;
import ballerina.log;
import ballerina.config;
import org.wso2.logFile;
import ballerina.runtime;

string username = config:getGlobalValue("DB_USER_NAME_EXT");
string password = config:getGlobalValue("DB_PASSWORD_EXT");
string hostOrPath = config:getGlobalValue("DB_HOST_EXT");
string dbName = config:getGlobalValue("DB_NAME_EXT");

sql:Parameter[][] issueArray = [];
sql:Parameter[][] pullRequestArray = [];
int port = 3306;
int pullRequestArrayIndex;
int issueArrayIndex;

@Description { value:"write pull requests and issues data into database"}
public function writeRawData(){
    endpoint<sql:ClientConnector> databaseConnector {
        //clientConnector;
        create sql:ClientConnector(sql:DB.MYSQL, hostOrPath, port, dbName+"?useSSL=false", username, password,
                                   {maximumPoolSize:5});
    }
    
    logFile:logInfo("Database connection established", runtime:getCallStack()[1].packageName);
    int[] update;
    try{
        int output = databaseConnector.update("TRUNCATE pullRequests",null);
        log:printInfo("Old entries in pullReuquests table are removed");
        logFile:logInfo("Old entries in pullReuquests table are removed", runtime:getCallStack()[1].packageName);
        output = databaseConnector.update("TRUNCATE issues",null);
        log:printInfo("Old entries in issues table are removed");
        logFile:logInfo("Old entries in issues table are removed", runtime:getCallStack()[1].packageName);
    }
    
    catch (error e) {
        log:printError("Error caused in deletion of existing data : " + e.message);
        logFile:logError("Error caused in deletion of existing data : " + e.message,
                         runtime:getCallStack()[1].packageName);
        databaseConnector.close();
    }
    try{
        update = databaseConnector.batchUpdate("INSERT INTO pullRequests
        (RepositoryName, Url, GithubId, Days, Weeks, State, CurrentTime) VALUES (?,?,?,?,?,?,?)", pullRequestArray);
        log:printInfo("New entries added to pullRequests");
        logFile:logInfo("New entries added to pullRequests", runtime:getCallStack()[1].packageName);
    }
    catch(error e){
        log:printError("Error caused in batch update : " + e.message);
        logFile:logError("Error caused in batch update : " + e.message , runtime:getCallStack()[1].packageName);
        databaseConnector.close();
    }
    try{
        update = databaseConnector.batchUpdate("INSERT INTO issues
        (RepositoryName, Url, GithubId, Days, Weeks, CurrentTime) VALUES (?,?,?,?,?,?)", issueArray);
        log:printInfo("New entries added to issues");
        logFile:logInfo("New entries added to issues", runtime:getCallStack()[1].packageName);
    }
    catch (error e) {
        log:printError("Error caused in batch update : " + e.message);
        logFile:logError("Error caused in batch update : " + e.message , runtime:getCallStack()[1].packageName);
    }
    finally{
        databaseConnector.close();
        log:printInfo("Database connection terminated");
        logFile:logInfo("Database connection terminated", runtime:getCallStack()[1].packageName);
    }
}

@Description { value:"Reading data from database"}
@Param { value:"tableName: Name of the table from which data has to be fetched"}
public function readData(string tableName)(json){
    endpoint<sql:ClientConnector> databaseConnector {
         create sql:ClientConnector(sql:DB.MYSQL, hostOrPath, port, dbName+"?useSSL=false", username, password,
                                                                                                          {maximumPoolSize:5});
    }
    string state = "";
    if(tableName == "pullRequests"){
        state = "State,";
    }
    
    // Query to return issues / pull requests sent by outsiders ,  repositories ,
    // respective product , url of issue and open duration by comparing
    // list of whole open issues / pull reuqests with list of users from WSO2
    // and product, repositories mapping.
    
    table filteredData = databaseConnector.select("SELECT ID,RepositoryName,Url,Days,Weeks," + state +
                                                  "githubId,product FROM "  + tableName +
                                                  " LEFT OUTER JOIN WSO2contributors ON " + tableName +
                                                  ".GithubId=WSO2contributors.userId LEFT OUTER JOIN product ON "+
                                                  tableName + ".RepositoryName=product.RepoName WHERE
                                                  WSO2contributors.userId is null",null,null);
    var jsonData, typeConversionError = <json>filteredData;
    if(typeConversionError != null){
        log:printError("Error in converting table to json : " + typeConversionError.message);
        logFile:logError("Error in converting table to json : " + typeConversionError.message,
                         runtime:getCallStack()[1].packageName);
    }
    else{
        var id , _ = (int) jsonData[0].ID;
        if(id > 0){
            log:printInfo("read filtered data from " + tableName);
            logFile:logInfo("read filtered data from " + tableName, runtime:getCallStack()[1].packageName);
        }
    }
    databaseConnector.close();
    return jsonData;
}

@Description { value:"Convert data from json to sql:Parameter type"}
@Param { value:"jsonPayload: json data read obtained from github API"}
@Param { value:"dataType: can be either issues or pull requests"}
public function generateData(json jsonPayload, string dataType){
    int iterator;
    sql:Parameter repoName;
    sql:Parameter url;
    sql:Parameter githubId;
    sql:Parameter openDays;
    sql:Parameter openWeeks;
    sql:Parameter state;
    sql:Parameter currentTime;
    sql:Parameter[] prParams = [];
    sql:Parameter[] issueParams = [];
    string githubID;
    string stringState;
    time:Time createdTime;
    int openFor;
    string createdAt;
    
    // Iterating through pull requests or issues from each repository and
    // generate data in sql:Parameter format.
    
    while(iterator < lengthof jsonPayload.nodes){
        repoName = {sqlType:sql:Type.VARCHAR, value:jsonPayload.nodes[iterator].repository.name.toString()};
        url = {sqlType:sql:Type.VARCHAR, value:jsonPayload.nodes[iterator].url.toString()};
        githubID = jsonPayload.nodes[iterator].author != null ?
                   jsonPayload.nodes[iterator].author.login.toString() : "null";
        githubId = {sqlType:sql:Type.VARCHAR, value:githubID};
        createdAt = jsonPayload.nodes[iterator].createdAt.toString();
        createdTime = time:parse(createdAt,"yyyy-MM-dd'T'HH:mm:ss'Z'");
        openFor = (time:currentTime().time - createdTime.time)/(1000*3600);
        openDays = {sqlType:sql:Type.INTEGER, value:(openFor/24)};
        openWeeks = {sqlType:sql:Type.INTEGER, value:(openFor/(24*7))};
        currentTime = {sqlType:sql:Type.DATETIME, value:time:currentTime()};
        
        if(dataType=="pullRequest"){
            if(lengthof jsonPayload.nodes[iterator].reviews.nodes == 1){
                stringState = jsonPayload.nodes[iterator].reviews.nodes[0].state.toString();
            }
            else{
                stringState = "REVIEW_REQUIRED";
            }
            state = {sqlType:sql:Type.VARCHAR, value:stringState};
            prParams = [repoName,url,githubId,openDays,openWeeks,state,currentTime];
            pullRequestArray[pullRequestArrayIndex] = prParams;
            pullRequestArrayIndex = pullRequestArrayIndex + 1;
        }
        else{
            issueParams = [repoName,url,githubId,openDays,openWeeks,currentTime];
            issueArray[issueArrayIndex] = issueParams;
            issueArrayIndex = issueArrayIndex + 1;
        }
        iterator = iterator + 1;
    }
}
