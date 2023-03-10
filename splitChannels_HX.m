function [blueData,blueTimes,hemoData,hemoTimes,stimOn,falseAlign,sRate] = splitChannels_HX(opts,trialNr, fileType)
% Code to separate blue and violet channel from widefield data. This needs
% analog data that contains a stimulus onset from which a pre and
% poststimulus dataset can be returned. Also requires trigger channels for
% blue/violet LEDs and some dark frames at the end.
% This code is the newer version of Widefield_CheckChannels.

if ~exist('fileType', 'var') || isempty(fileType)
    fileType = '.dat';
end
falseAlign = false;

%% load data and check channel identity
cFile = [opts.fPath filesep 'Analog_' num2str(trialNr) '.dat']; %current file to be read
[~,Analog] = loadRawData_HX(cFile,'Analog'); %load analog data
Analog = double(Analog);

load([opts.fPath filesep 'frameTimes_' num2str(trialNr, '%04i') '.mat'], 'imgSize', 'frameTimes'); %get data size
frameTimes = frameTimes * 86400*1e3; %convert to seconds
cFile = [opts.fPath filesep opts.fName '_' num2str(trialNr, '%04i') fileType]; %current file to be read
[~, data] = loadRawData_HX(cFile,'Frames',[], imgSize); %load video data

%reshape data to compute mean frame intensities
dSize = size(data);
data = reshape(data,[],dSize(end));
temp = zscore(mean(single(data)));
data = squeeze(reshape(data,dSize));

bFrame = find(temp < min(temp)*.75); %index for black frames
if bFrame(1) == 1 %if first frame is dark, remove initial frames from data until LEDs are on
    %remove initial dark frames
    cIdx = find(diff(bFrame) > 1, 1); 
    data(:,:,1:cIdx) = [];
    dSize = size(data);
    temp(1:cIdx) = [];
    frameTimes(1:cIdx) = [];
end

%determine imaging rate - either given as input or determined from data
if isfield(opts,'frameRate')
    sRate = opts.frameRate;
else
    sRate = 1000/(mean(diff(frameTimes))*2);
end

% check if pre- and poststim are given. use all frames if not.
if ~isfield(opts,'preStim') || ~isfield(opts,'postStim')
    opts.preStim = 0;
    opts.postStim = inf;
else
    opts.preStim = ceil(opts.preStim * sRate);
    opts.postStim = ceil(opts.postStim * sRate);
end

if any(~isnan(opts.trigLine)) || any(opts.trigLine > size(Analog,1))
    
    trace = Analog(opts.trigLine,:); %blue and violet light trigger channels
    trace = zscore(trace(1,end:-1:1) - trace(2,end:-1:1)); %invert and subtract to check color of last frame
    trace(round(diff(trace)) ~= 0) = 0; %don't use triggers that are only 1ms long
    lastBlue = find(trace > 1, 1);
    lastHemo = find(trace < -1,1);
    
    blueLast = lastBlue < lastHemo;
    if isempty(lastBlue) || isempty(lastHemo)
        warning(['Failed to find trigger signals. lastBlue: ' num2str(lastBlue) '; lastHemo: ' num2str(lastHemo) '; trialNr: ' num2str(trialNr)])
    end
   
    bFrame = find(temp < min(temp)*.75); %index for first black frame (assuming the last frame is really a dark frame)
    bFrame(bFrame < round(size(temp,2) / 2)) = []; %make sure black frame is in the second half of recording.
    
    if isempty(bFrame); bFrame = length(temp); end %if there are no black frames, just use the last one
    bFrame = bFrame(1);

    blueInd = false(1,length(temp));

    if blueLast %last frame before black is blue
        if rem(bFrame,2) == 0 %blue frames (bFrame - 1) have uneven numbers
            blueInd(1:2:dSize(end)) = true;
        else
            blueInd(2:2:dSize(end)) = true;
        end
        lastFrame = size(Analog,2) - lastBlue; %index for end of last frame
    else %last frame before black is violet
        if rem(bFrame,2) == 0 %blue frames (bFrame - 2) have even numbers
            blueInd(2:2:dSize(end)) = true;
        else
            blueInd(1:2:dSize(end)) = true;
        end
        lastFrame = size(Analog,2) - lastHemo; %index for end of last frame
    end
    
%     %get number of rejected frames before data was saved
%     nrFrames = bFrame - 1; %number of exposed frames in the data
%     nrTriggers = size(find(diff(Analog(opts.trigLine(1),:))> 2500),2) + size(find(diff(Analog(opts.trigLine(2),:))> 2500),2); %nr of triggers
%     removedFrames = nrTriggers - nrFrames;
%     save([opts.fPath filesep 'frameTimes_' num2str(trialNr, '%04i') '.mat'], 'imgSize', 'frameTimes', 'removedFrames'); %get data size

    %realign frameTime based on time of last non-dark frame
    frameTimes = (frameTimes - frameTimes(bFrame - 1)) + lastFrame;
    blueInd = blueInd(frameTimes < size(Analog,2));
    blueInd(bFrame - 1:end) = []; %exclude black and last non-black frame
    
    blueTimes = frameTimes(blueInd);
    hemoTimes = frameTimes(~blueInd);
    
    blueData = data(:,:,blueInd);
    hemoData = data(:,:,~blueInd);
    
    % find all triggers in stim line and choose the one that is on the longest as the true stimulus trigger
    % apparently this line can be contaminated by noise
    stimOn = find(diff(double(Analog(opts.stimLine,:)) > 1500) == 1);
    stimOff = find(diff(double(Analog(opts.stimLine,:)) > 1500) == -1);
    ind = find((stimOff - stimOn(1:length(stimOff))) > 2,1); %only use triggers that are more than 2ms long
    stimOn = stimOn(ind) + 1;
    
    if ~isinf(opts.postStim)
        if isempty(stimOn) || isempty(find((blueTimes - stimOn) > 0, 1))
            error(['No stimulus trigger found. Current file: ' cFile])
        else
            blueStim = find((blueTimes - stimOn) > 0, 1);  %first blue frame after stimOn
            if blueStim <= opts.preStim + 1 %if stim occured earlier as defined by preStim
                blueStim = opts.preStim + 1 ; %use earliest possible frame for stimulus onset
                if (find(hemoTimes - blueTimes(opts.preStim + 1) > 0, 1) - 1) <= opts.preStim %make sure there are enough frames for hemo channel
                    blueStim = blueStim + 1 ; %use earliest possible frame for stimulus onset
                end
                fprintf('Warning: StimOn is too early. Starting at %d instead of %d to provide enough baseline frames.\n',blueStim, find((blueTimes - stimOn) > 0, 1))
                falseAlign = true;
            end
        end
        
        if length(blueTimes) < (blueStim + opts.postStim - 1)
            lastBlueIdx = length(blueTimes);
        else
            lastBlueIdx = blueStim + opts.postStim - 1;
        end
        
        hemoStim = find(hemoTimes - blueTimes(blueStim) > 0, 1) - 1;  %first hemo frame before blueFrame after stimOn :)
        if length(hemoTimes) < (hemoStim + opts.postStim - 1)
            lastHemoIdx = length(hemoTimes);
        else
            lastHemoIdx = hemoStim + opts.postStim - 1;
        end
        
        %make sure both channels have equal length
        chanDiff = length(blueStim - opts.preStim : lastBlueIdx) - length(hemoStim - opts.preStim : lastHemoIdx);
        if chanDiff < 0 %less blue frames, cut hemo frame
            lastHemoIdx = lastHemoIdx + chanDiff;
        elseif chanDiff > 0 %less hemo frames, cut blue frame
            lastBlueIdx = lastBlueIdx - chanDiff;
        end
        
        %check if enough data is remaining after stimulus onset
        if lastBlueIdx - blueStim + 1  < opts.postStim
            fprintf('Warning: StimOn is too late. Using %d instead of %d frames for poststim data.\n',lastBlueIdx - blueStim, opts.postStim)
            falseAlign = true;
        end
        
        blueTimes = blueTimes(blueStim - opts.preStim : lastBlueIdx); %get blue frame times before and after stimOn
        blueData = blueData(:, :, blueStim - opts.preStim : lastBlueIdx); %get blue frame data before and after stim on
        
        hemoTimes = hemoTimes(hemoStim - opts.preStim : lastHemoIdx); %get hemo frame times before and after stimOn
        hemoData = hemoData(:,:,hemoStim - opts.preStim : lastHemoIdx); %get hemo frame data before and after stim on
        
    else
        %make sure both channels have equal length
        chanDiff = size(blueData,3) - size(hemoData,3);
        if chanDiff < 0 %less blue frames, cut hemo frame
            hemoData = hemoData(:,:,1:end+chanDiff);
            hemoTimes = hemoTimes(1:end+chanDiff);
        elseif chanDiff > 0 %less hemo frames, cut blue frame
            blueData = blueData(:,:,1:end-chanDiff);
            blueTimes = blueTimes(1:end-chanDiff);
        end
        
        % check for stimulus onset
        if isempty(stimOn) || isempty(find((blueTimes - stimOn) > 0, 1))
            warning(['No stimulus trigger found. Current file: ' cFile])
            stimOn = NaN;
        else
            stimOn = find((blueTimes - stimOn) > 0, 1);  %first blue frame after stimOn
        end
    end
    
    %make sure each frame has a corresponding trigger signal
    frameDiff = floor(mean(diff(frameTimes)));
    frameJitter = sum(diff(frameTimes) > (frameDiff + 1));
    frameDiff = frameDiff - (1 - rem(frameDiff,2)); %make sure, inter-frame interval is uneven number
    blueInd = bsxfun(@minus, repmat(round(blueTimes),1,frameDiff),-floor(frameDiff/2):floor(frameDiff/2))'; %get index for each frameTime and get half the IFI before and after frame was acquired to check trigger signal.
    hemoInd = bsxfun(@minus, repmat(round(hemoTimes),1,frameDiff),-floor(frameDiff/2):floor(frameDiff/2))'; %get index for each frameTime and get half the IFI before and after frame was acquired to check trigger signal.
    
    blueTrig = zscore(Analog(opts.trigLine(1), blueInd(:))); %blue light trigger channel
    blueTrig = reshape(blueTrig, [], length(blueTimes));
    blueTrig = any(zscore(blueTrig) > 0.5);
    
    hemoTrig = zscore(Analog(opts.trigLine(2), hemoInd(:))); %blue light trigger channel
    hemoTrig = reshape(hemoTrig, [], length(hemoTimes));
    hemoTrig = any(zscore(hemoTrig) > 0.5);

    if sum(blueTrig) ~= length(blueTimes) || sum(hemoTrig) ~= length(hemoTimes)
        disp(['Potential frame time violations: ' num2str(frameJitter)])
        disp(['Confirmed blue trigs: ' num2str(sum(blueTrig)) '; blue frame times: ' num2str(length(blueTimes))])
        disp(['Confirmed hemo trigs: ' num2str(sum(hemoTrig)) '; hemo frame times: ' num2str(length(hemoTimes))])
        
        if frameJitter < (length(blueTimes) - sum(blueTrig)) || frameJitter < (length(hemoTimes) - sum(hemoTrig)) %more unaccounted triggers as might be explained by frame time jitter
            falseAlign = true; %potential for misaligned channel separation. Don't use trial.
            disp('Flagged file for rejection.')
        end
        disp(['Current file: ' cFile])
    end
else
    blueData = data(:,:,1 : opts.preStim + opts.postStim);
    blueTimes = frameTimes(1: opts.preStim + opts.postStim);
    hemoData = NaN;
    hemoTimes = NaN;
    falseAlign = true;
    stimOn = [];
    sRate = 1000/(mean(diff(frameTimes)));
end

%% plot result if requested
if opts.plotChans
    figure(50) %show result
    subplot(1,2,1); colormap gray
    imagesc(mean(blueData,3)); axis image
    title(['Blue frame average - Trial ' num2str(trialNr)])
    subplot(1,2,2);
    imagesc(mean(hemoData,3)); axis image
    title(['Hemo frame average - Trial ' num2str(trialNr)])
    drawnow;
end
end
