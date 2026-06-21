%% ========== 全自动卷积核（高斯模糊 / 锐化 / 左正右负边缘检测） - 修正边缘检测缩放 ==========
clear; close all; clc;

%% 1. 读取 I-t 曲线
[dataFile, dataPath] = uigetfile({'*.csv;*.xlsx;*.txt'},'选择 I-t 曲线');
if isequal(dataFile,0); error('未选择数据文件'); end
fullDataPath = fullfile(dataPath, dataFile);
[~,~,ext] = fileparts(dataFile);
if strcmpi(ext, '.csv')
    data = csvread(fullDataPath);
elseif strcmpi(ext, '.xlsx')
    [~,~,data] = xlsread(fullDataPath);
    if iscell(data); data = cell2mat(data); end
else
    data = load(fullDataPath);
end

time = data(:,1); current = data(:,2);
valid = isfinite(time) & isfinite(current);
time = time(valid); current = current(valid);
[time, idx] = unique(sort(time), 'stable'); current = current(idx);
[peakCurrent, idxPeak] = max(current);
peakTime = time(idxPeak);
fprintf('峰值电流 = %.6f @ t = %.6f\n', peakCurrent, peakTime);

%% 2. 选择卷积核类型
fprintf('\n========== 卷积核类型 ==========\n');
fprintf('1. 高斯模糊\n');
fprintf('2. 锐化\n');
fprintf('3. 边缘检测 (左正右负)\n');
typeChoice = input('请输入序号 (1/2/3): ');
while ~ismember(typeChoice, [1,2,3])
    typeChoice = input('重新输入: ');
end

%% 3. 构造原始电流核（匹配实际电流）
rawKernel = zeros(3,3);
switch typeChoice
    case 1  % 高斯模糊
        targetEdge = peakCurrent * 0.5;
        targetCorner = peakCurrent * 0.25;
        [edgeCurr, ~] = findNearestCurrent(targetEdge, time, current, idxPeak, 'after');
        [cornerCurr, ~] = findNearestCurrent(targetCorner, time, current, idxPeak, 'after');
        fprintf('高斯模糊: 边电流 = %.6f, 角电流 = %.6f\n', edgeCurr, cornerCurr);
        rawKernel = [ cornerCurr, edgeCurr, cornerCurr;
                      edgeCurr,   peakCurrent, edgeCurr;
                      cornerCurr, edgeCurr, cornerCurr ];
        kernelName = 'Gaussian_Blur';
        
    case 2  % 锐化
        targetEdge = peakCurrent * 0.2;   % 四周目标为峰值的20%
        [edgeCurr, ~] = findNearestCurrent(targetEdge, time, current, idxPeak, 'after');
        fprintf('锐化: 四周电流 = %.6f (取负)\n', edgeCurr);
        rawKernel = [ 0, -edgeCurr, 0;
                     -edgeCurr, peakCurrent, -edgeCurr;
                      0, -edgeCurr, 0 ];
        kernelName = 'Sharpening';
        
    case 3  % 边缘检测：左正右负
        targetVal = peakCurrent;
        [matchCurr, ~] = findNearestCurrent(targetVal, time, current, idxPeak, 'before');
        fprintf('边缘检测: 匹配电流 = %.6f (左列正, 右列负)\n', matchCurr);
        rawKernel = [  matchCurr, 0, -matchCurr;
                       matchCurr, 0, -matchCurr;
                       matchCurr, 0, -matchCurr ];
        kernelName = 'Edge_Detect_LeftPos_RightNeg';
end

fprintf('\n原始电流核（未经缩放）:\n');
disp(rawKernel);
rawSum = sum(rawKernel(:));

%% 4. 缩放：边缘检测特殊处理（使最大系数绝对值为1），其他使核和为1
if typeChoice == 3
    % 边缘检测核和为0，无法归一化和。改为使核的最大系数为1（即左列系数为±1）
    maxCoeff = max(abs(rawKernel(:)));
    if maxCoeff == 0
        scale = 1;
    else
        scale = 1 / maxCoeff;
    end
    fprintf('边缘检测核: 缩放因子使最大系数=1, scale = %.6f\n', scale);
else
    if abs(rawSum) < 1e-12
        warning('原始核的和接近零，使用 scale=1');
        scale = 1;
    else
        scale = 1 / rawSum;
        fprintf('自动缩放因子 = %.6f\n', scale);
    end
end

kernel = rawKernel * scale;
fprintf('\n最终卷积核 (和=%.6f):\n', sum(kernel(:)));
disp(kernel);

%% 5. 读取图像并卷积
[imgFile, imgPath] = uigetfile({'*.jpg;*.png;*.bmp;*.tif'},'选择图像');
if isequal(imgFile,0)
    I = imread('cameraman.tif'); isGray = true; imgName = 'cameraman';
else
    I = imread(fullfile(imgPath, imgFile)); 
    isGray = (size(I,3)==1);
    [~, imgName, ~] = fileparts(imgFile);
end
origImg = I;

if isGray
    convResult = conv2(double(origImg), kernel, 'same');
else
    convResult = zeros(size(origImg), 'double');
    for c = 1:3
        convResult(:,:,c) = conv2(double(origImg(:,:,c)), kernel, 'same');
    end
end

% 显示：clip到[0,255]后除以255
minVal = min(convResult(:)); maxVal = max(convResult(:));
convResultClipped = max(0, min(255, convResult));
convResultDisplay = convResultClipped / 255;
if minVal < 0 || maxVal > 255
    fprintf('卷积结果范围 [%.2f, %.2f]，已clip到[0,255]显示\n', minVal, maxVal);
end

figure('Name','卷积对比','NumberTitle','off');
subplot(1,2,1); imshow(origImg); title('原始图像');
subplot(1,2,2); imshow(convResultDisplay); title(sprintf('结果: %s', kernelName));
set(gcf,'Position',[100,100,900,400]);

%% 6. 定量指标
if ~isGray
    procGray = rgb2gray(uint8(convResultClipped));
    origGray = rgb2gray(origImg);
else
    procGray = uint8(convResultClipped);
    origGray = origImg;
end
mse = mean((double(procGray(:)) - double(origGray(:))).^2);
psnrVal = 10*log10(255^2/mse);
if exist('ssim','file')==2
    ssimVal = ssim(procGray, origGray);
else
    K = [0.01 0.03]; L = 255;
    window = fspecial('gaussian', 11, 1.5);
    mu1 = filter2(window, double(origGray), 'same');
    mu2 = filter2(window, double(procGray), 'same');
    sigma1_sq = filter2(window, double(origGray).^2, 'same') - mu1.^2;
    sigma2_sq = filter2(window, double(procGray).^2, 'same') - mu2.^2;
    sigma12 = filter2(window, double(origGray).*double(procGray), 'same') - mu1.*mu2;
    C1 = (K(1)*L)^2; C2 = (K(2)*L)^2;
    ssim_map = ((2*mu1.*mu2 + C1).*(2*sigma12 + C2)) ./ ((mu1.^2+mu2.^2+C1).*(sigma1_sq+sigma2_sq+C2));
    ssimVal = mean(ssim_map(:));
end
snrOrig = mean(origGray(:)) / (std(double(origGray(:)))+eps);
snrProc = mean(procGray(:)) / (std(double(procGray(:)))+eps);
snrImprove = (snrProc - snrOrig) / snrOrig * 100;
sobelX = [-1 0 1; -2 0 2; -1 0 1];
sobelY = sobelX';
gradOrig = sqrt(conv2(double(origGray),sobelX,'same').^2 + conv2(double(origGray),sobelY,'same').^2);
gradProc = sqrt(conv2(double(procGray),sobelX,'same').^2 + conv2(double(procGray),sobelY,'same').^2);
edgeRatio = mean(gradProc(:)) / (mean(gradOrig(:))+eps);

fprintf('\n========== 定量指标 ==========\n');
fprintf('PSNR: %.2f dB\n', psnrVal);
fprintf('SSIM: %.4f\n', ssimVal);
fprintf('SNR 改善: %.2f %%\n', snrImprove);
fprintf('边缘对比度增强因子: %.4f\n', edgeRatio);

%% 7. 保存报告
txtName = [imgName '_' kernelName '_report.txt'];
fid = fopen(txtName, 'w');
fprintf(fid, '全自动卷积报告\n时间: %s\n数据: %s\n图像: %s\n峰值电流: %.6f\n', ...
    datestr(now), dataFile, imgFile, peakCurrent);
fprintf(fid, '卷积核类型: %s\n', kernelName);
fprintf(fid, '原始核:\n'); 
for r=1:3, fprintf(fid, '%12.6f ', rawKernel(r,:)); fprintf(fid,'\n'); end
fprintf(fid, '缩放因子: %g\n', scale);
fprintf(fid, '最终核:\n');
for r=1:3, fprintf(fid, '%12.6f ', kernel(r,:)); fprintf(fid,'\n'); end
fprintf(fid, '核和: %.6f\n', sum(kernel(:)));
fprintf(fid, 'PSNR: %.2f\nSSIM: %.4f\nSNR改善: %.2f%%\n边缘因子: %.4f\n', ...
    psnrVal, ssimVal, snrImprove, edgeRatio);
fclose(fid);
fprintf('报告已保存: %s\n', txtName);

%% 8. 保存图像
answer = input('\n保存结果图像？ (y/n): ','s');
if strcmpi(answer,'y')
    [saveFile, savePath] = uiputfile({'*.jpg;*.png'},'保存图像', [imgName '_' kernelName '.png']);
    if ~isequal(saveFile,0)
        imwrite(convResultDisplay, fullfile(savePath, saveFile));
        fprintf('图像保存至: %s\n', fullfile(savePath, saveFile));
    end
end

disp('程序运行完毕。');

%% 辅助函数
function [actualCurr, foundTime] = findNearestCurrent(targetCurr, time, current, peakIdx, direction)
    if strcmp(direction, 'after')
        range = peakIdx:length(current);
    else
        range = 1:peakIdx;
    end
    [~, idx] = min(abs(current(range) - targetCurr));
    actualIdx = range(idx);
    actualCurr = current(actualIdx);
    foundTime = time(actualIdx);
end