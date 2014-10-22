% binary image collection from a video file
classdef VideoImageCollection < handle
	properties
	videoFileName;
	minArea;  % FIXME: not implemented yet
	largerThan;
	risk;
	videoReader;
	nImages;
	backgroundMeans;
	backgroundSDs;
	saturationMeans;
	%----------------%
	videoStart;
	mocapScaling;
	associatedMotions;  % associated MotionCollection object
	end

	methods
	function obj = VideoImageCollection(videoFileName, varargin)
	% largerThan: 
	%   returns all components, if <= 0
	%   returns the largest component, if == Inf
	%   returns components whose areas >= `largerThan`, otherwise

		p = inputParser;
		addRequired(p, 'videoFileName', @(x) exist(x, 'file') == 2);
		addParamValue(p, 'largerThan', Inf, @isnumeric);
		addParamValue(p, 'risk', 1, @isnumeric);
		parse(p, videoFileName, varargin{:});

		obj.videoFileName = p.Results.videoFileName;
		obj.largerThan = p.Results.largerThan;
		obj.risk = p.Results.risk;

		matchNames = regexp(obj.videoFileName, '\(C(?<camID>\d+)\).avi', 'names');
		camID = str2num(matchNames.camID);
		
		bgFileName = [CONFIG.BG_PATH ...
			'Background_(C' num2str(camID) ').mat'];
		load(bgFileName);  % bg_means & bg_vars

		obj.backgroundMeans = bg_means;
		obj.backgroundSDs = cellfun(@sqrt, bg_vars, 'UniformOutput', false);
		obj.videoReader = VideoReader(videoFileName);
		obj.nImages = obj.videoReader.NumberOfFrames;

		% prepares for shadow removal
		for i = 1:length(obj.backgroundMeans)
			[~, obj.saturationMeans{i}, ~] = rgb2hsv(obj.backgroundMeans{i});
		end

		% synchronization
		ofsFile = regexprep(obj.videoFileName, ...
			'\\Image_Data\\(.+)\.avi', '\\Sync_Data\\$1\.ofs');
		offset = load(ofsFile);
		obj.videoStart = offset(1);
		obj.mocapScaling = offset(3);

	end

	% Overloading `subsref` involves tedious work, so just keep things 
	% simple here.
	function bw = at(obj, ind)
		image = double(read(obj.videoReader, ind)) / 255;

		% Computes per-pixel probability that it belongs to
		% background.
		lenSampledScenes = length(obj.backgroundMeans);
		bg_prob = zeros(size(image, 1), size(image, 2));
		for M = 1:lenSampledScenes
			bg_prob = bg_prob + prod(normpdf(image, ... 
				obj.backgroundMeans{M}, obj.backgroundSDs{M}), 3);
		end

		% Classifies each pixel based on the assumption that foreground
		% is distributed according to uniform distribution.
		bw = (bg_prob / lenSampledScenes) < (1 / (256*256*256* obj.risk));

		cc = bwconncomp(bw);

		if obj.largerThan <= 0
			idxFore = 1:length(cc.PixelIdxList);
		else
			areas = cellfun(@numel, cc.PixelIdxList);
			bw = false(size(bw));

			if obj.largerThan == Inf
				% only returns the largest component
				[~, idxFore] = max(areas);
				bw(cc.PixelIdxList{idxFore}) = true;
			else
				idxFore = find(areas >= obj.largerThan);
				for i = idxFore
					bw(cc.PixelIdxList{i}) = true;
				end
			end
		end
		
		[pxlIdxR, pxlIdxC] = ...
			ind2sub(size(bw), vertcat(cc.PixelIdxList{idxFore}));
		minR = min(pxlIdxR); maxR = max(pxlIdxR);
		minC = min(pxlIdxC); maxC = max(pxlIdxC);

		shadowProportion = 0.2;
		shadowHeight = ceil((maxR - minR + 1) * shadowProportion);
		shadowRFrom = maxR - shadowHeight + 1;

		% the lower part of the region of interest
		roiBottom = image(shadowRFrom:maxR, minC:maxC, :);
		satBackground = cell(size(obj.saturationMeans));
		for i = 1:length(satBackground)
			satBackground{i} = ...
				obj.saturationMeans{i}(shadowRFrom:maxR, minC:maxC);
		end

		% shadow removal
		notShadow = obj.removeShadow(roiBottom, satBackground);
		% imshow(notShadow); pause;
		bw(shadowRFrom:maxR, minC:maxC) = ...
			bw(shadowRFrom:maxR, minC:maxC) & notShadow;

		% fills the gaps, removes noise
		bw = medfilt2(bw, [7 7]);
	end

	% function pose = associatedPoseAt(obj, ind)
	% 	% MocapIndex = MOCAP_ST + (ImageIndex - IM_ST) * MOCAP_SC
	% 	mocapInd = mocapStart + (validToAll(ind) - videoStart) * mocapScaling;
	% end

	function [] = saveSnapshots(obj)
		function [videoInd, mocapInd] = sync(packedMocap)
		% Converts the index in mocap stream into that in video stream.
			
			% [1 0 2 3 4 0]' => logical([1 0 1 1 1 0]')
			validMocapInd = packedMocap.frameNo ~= 0;
			% logical([1 0 1 1 1 0]') => [1 3 4 5]
			mocapInd = find(validMocapInd);

			% [1 3 4 5]' => [1 2 3 3]', 
			% if `videoStart` = 1, `mocapScaling` = 2.
			videoInd = obj.videoStart + ...
				round((mocapInd - 1) / obj.mocapScaling);

			% [1 2 3 3]' => logical([1 1 1 0]')
			indicator = [true; logical(diff(videoInd))];
			videoInd = videoInd(indicator);
			mocapInd = mocapInd(indicator);
		end

		% suppose that only C1 of Trial 1 is used here
		matched = regexp(obj.videoFileName, ...
			'(?<subject>S\d)\\Image_Data\\(?<action_trial>[\w]+)_\(C1\)\.avi', ...
				'names');
		motionsStruct = obj.associatedMotions.motions;
		packed = motionsStruct.(matched.subject).(matched.action_trial);
		[videoInd, mocapInd] = sync(packed);

		destDir = fullfile(CONFIG.SNAPSHOT_PATH, ...
			matched.subject, 'Image_Data', matched.action_trial);
		if exist(destDir, 'file') ~= 7
			mkdir(destDir);
		end

		for i = 1:length(videoInd)
			bw = obj.at(videoInd(i));
			destPath = fullfile(destDir, ...
				['C0-' num2str(mocapInd(i), '%04d') '.jpg']);
			imwrite(bw, destPath);
		end

	end
	end

	methods (Static)
	function notShadow = removeShadow(roiBottom, saturation)
	% Input:
	%   roiBottom: the lower part of the region of interest, 
	%     (h * w * 3) array, in range 0 ~ 1;
	%   saturation: corresponding average saturation of backgrounds; 
	% 
	% Output:
	%   notShadow: h-by-w logical array

		[~, s, ~] = rgb2hsv(roiBottom);
		notShadow = false(size(s));
		
		for i = 1:length(saturation)
			notShadow = notShadow | (saturation{i} * 0.8 < s < saturation{i});
		end
	end
	end
end


