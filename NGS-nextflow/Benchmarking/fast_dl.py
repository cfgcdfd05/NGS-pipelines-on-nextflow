#!/usr/bin/env python3
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
import urllib.request

def get_content_length(url):
    req = urllib.request.Request(url, method='HEAD')
    with urllib.request.urlopen(req) as resp:
        return int(resp.headers['Content-Length'])

def download_chunk(url, start, end, chunk_idx, temp_file, max_retries=5):
    for attempt in range(max_retries):
        try:
            req = urllib.request.Request(url)
            req.add_header('Range', f'bytes={start}-{end}')
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = resp.read()
            if len(data) != (end - start + 1):
                raise ValueError(f"Expected {end-start+1} bytes, got {len(data)}")
            with open(temp_file, 'r+b') as f:
                f.seek(start)
                f.write(data)
            return chunk_idx, len(data)
        except Exception as e:
            if attempt == max_retries - 1:
                raise e
            time.sleep(1 + attempt)

def fast_download(url, output_path, num_threads=16):
    total_size = get_content_length(url)
    print(f"Downloading {url} -> {output_path} ({total_size / (1024*1024):.2f} MB) with {num_threads} threads...", flush=True)
    with open(output_path, 'wb') as f:
        f.truncate(total_size)
    
    chunk_size = (total_size + num_threads - 1) // num_threads
    futures = []
    with ThreadPoolExecutor(max_workers=num_threads) as executor:
        for i in range(num_threads):
            start = i * chunk_size
            if start >= total_size:
                break
            end = min((i + 1) * chunk_size - 1, total_size - 1)
            futures.append(executor.submit(download_chunk, url, start, end, i, output_path))
        
        downloaded = 0
        t0 = time.time()
        for f in as_completed(futures):
            idx, length = f.result()
            downloaded += length
            elapsed = time.time() - t0
            speed = downloaded / (1024 * 1024 * max(elapsed, 0.1))
            print(f"Progress: {downloaded/(1024*1024):.1f}/{total_size/(1024*1024):.1f} MB ({downloaded/total_size*100:.1f}%) - {speed:.2f} MB/s", flush=True)
            
    print(f"Finished {output_path} in {time.time() - t0:.1f}s", flush=True)

if __name__ == '__main__':
    os.makedirs('data/raw_actual', exist_ok=True)
    u1 = "https://giab.s3.amazonaws.com/data/NA12878/Garvan_NA12878_HG001_HiSeq_Exome/NIST7035_TAAGGCGA_L001_R1_001.fastq.gz"
    u2 = "https://giab.s3.amazonaws.com/data/NA12878/Garvan_NA12878_HG001_HiSeq_Exome/NIST7035_TAAGGCGA_L001_R2_001.fastq.gz"
    if not os.path.exists('data/raw_actual/sample1_R1.fastq.gz') or os.path.getsize('data/raw_actual/sample1_R1.fastq.gz') < 1900000000:
        fast_download(u1, 'data/raw_actual/sample1_R1.fastq.gz', 16)
    if not os.path.exists('data/raw_actual/sample1_R2.fastq.gz') or os.path.getsize('data/raw_actual/sample1_R2.fastq.gz') < 1900000000:
        fast_download(u2, 'data/raw_actual/sample1_R2.fastq.gz', 16)
